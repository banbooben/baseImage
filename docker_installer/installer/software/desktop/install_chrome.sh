#!/bin/bash
###
 # Install Google Chrome under /deployment/software/chrome.
 # Layer layout (COPY-friendly):
 #   /deployment/software/chrome/               # extracted .deb (opt/, usr/, etc.)
 #   /deployment/software/chrome/data/          # user-data-dir (runtime)
 #   /deployment/bin/chrome                     # launcher
 #
 # Upstream: https://www.google.com/chrome/
 # 默认跟随 Google Chrome stable latest；仅在需要时覆盖：CHROME_PIN_VERSION=131.0.6778.85-1
 # arm64 架构下 Google 不提供官方 .deb，降级为 Chromium PPA。
###
source /deployment/scripts/common.sh

check_target_arch(){
  ARCH=$(uname -m)
  case $ARCH in
    x86_64|amd64)
      TARGET_ARCH="amd64"
      ;;
    aarch64|arm64)
      TARGET_ARCH="arm64"
      ;;
    *)
      echo "未知架构: $ARCH"
      exit 1
      ;;
  esac
  export TARGET_ARCH
  echo "目标架构: $TARGET_ARCH"
}

setEnv(){
  check_target_arch
  export DEBIAN_FRONTEND=noninteractive
  export INSTALL_PATH=/deployment/software/chrome
  export CHROME_DATA="${INSTALL_PATH}/data"
  export CHROME_PIN_VERSION="${CHROME_PIN_VERSION:-}"

  if [ "$TARGET_ARCH" = "amd64" ]; then
    echo "Google Chrome ${CHROME_PIN_VERSION:-latest stable} (${TARGET_ARCH})"
  else
    echo "Google Chrome 无 arm64 .deb，降级为 Chromium (${TARGET_ARCH})"
  fi
}

installDeps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  # noble 上非 t64 包名（如 libasound2）会自动解析到 t64 版本，无需写两遍
  apt-get install -y --no-install-recommends \
    ca-certificates wget \
    libgtk-3-0 libx11-6 libxcb1 libxtst6 libxfixes3 \
    libnss3 libnspr4 libgbm1 \
    libasound2 \
    libatk-bridge2.0-0 libatspi2.0-0 \
    libcups2 libdrm2 libxcomposite1 libxdamage1 libxrandr2 \
    libxkbcommon0 libpango-1.0-0 libcairo2 \
    libu2f-udev \
    fonts-liberation fonts-noto-cjk fonts-noto-color-emoji \
    xdg-utils
  apt-get clean -y
  rm -rf /var/lib/apt/lists/*
}

installChrome(){
  local extract_tmp="/tmp/chrome-extract"
  mkdir -p /deployment/software /deployment/bin
  rm -rf "${INSTALL_PATH}" "${extract_tmp}"
  mkdir -p "${extract_tmp}"

  if [ "$TARGET_ARCH" = "amd64" ]; then
    # ── Google Chrome (amd64) ──────────────────────────────────
    local archive deb_url
    if [ -n "${CHROME_PIN_VERSION}" ]; then
      archive="google-chrome-stable_${CHROME_PIN_VERSION}_amd64.deb"
      deb_url="https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/${archive}"
    else
      archive="google-chrome-stable_current_amd64.deb"
      deb_url="https://dl.google.com/linux/direct/${archive}"
    fi
    local tmp="/tmp/${archive}"

    echo "Download Google Chrome: ${deb_url}"
    wget -q --timeout=180 -O "${tmp}" "${deb_url}" || {
      echo "Failed to download ${deb_url}" >&2
      return 1
    }

    dpkg-deb -x "${tmp}" "${extract_tmp}"
    CHROME_VERSION="$(dpkg-deb -f "${tmp}" Version | sed 's/-[0-9].*//')"
    rm -f "${tmp}"
  else
    # ── Chromium (arm64 fallback) ──────────────────────────────
    echo "Installing Chromium for arm64..."
    apt-get update
    apt-get install -y --no-install-recommends software-properties-common
    add-apt-repository ppa:xtradeb/apps -y
    apt-get update
    apt-get install -y --no-install-recommends \
      chromium chromium-codecs-ffmpeg \
      libva-drm2 libva-x11-2 libva-wayland2

    # 将系统安装的 chromium 文件复制到 INSTALL_PATH，保持 COPY-friendly 布局
    mkdir -p "${INSTALL_PATH}/usr/bin" \
             "${INSTALL_PATH}/usr/lib" \
             "${INSTALL_PATH}/usr/share"

    # 复制 chromium 二进制和相关库
    if [ -x /usr/bin/chromium ]; then
      cp -a /usr/bin/chromium "${INSTALL_PATH}/usr/bin/"
    elif [ -x /usr/bin/chromium-browser ]; then
      cp -a /usr/bin/chromium-browser "${INSTALL_PATH}/usr/bin/"
    fi

    # 复制 chromium 相关的 .so（避免缺失依赖）
    for libdir in /usr/lib/$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || echo "aarch64-linux-gnu"); do
      if [ -d "${libdir}" ]; then
        mkdir -p "${INSTALL_PATH}${libdir}"
        cp -an "${libdir}"/libchromium* "${INSTALL_PATH}${libdir}/" 2>/dev/null || true
      fi
    done

    # 复制 chromium 资源文件
    if [ -d /usr/share/chromium ]; then
      cp -a /usr/share/chromium "${INSTALL_PATH}/usr/share/" 2>/dev/null || true
    elif [ -d /usr/share/chromium-browser ]; then
      cp -a /usr/share/chromium-browser "${INSTALL_PATH}/usr/share/" 2>/dev/null || true
    fi

    # 复制应用图标
    for d in applications pixmaps icons; do
      if [ -e /usr/share/${d} ]; then
        mkdir -p "${INSTALL_PATH}/usr/share/${d}"
      fi
    done

    CHROME_VERSION="$(chromium --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")"
    apt-get clean -y
  fi

  # ── 移动到 INSTALL_PATH ─────────────────────────────────────
  mkdir -p "${INSTALL_PATH}"
  for d in opt usr etc; do
    if [ -d "${extract_tmp}/${d}" ]; then
      # 避免覆盖 arm64 已复制的文件
      cp -an "${extract_tmp}/${d}"/* "${INSTALL_PATH}/${d}/" 2>/dev/null || true
    fi
  done
  rm -rf "${extract_tmp}"

  export CHROME_VERSION="${CHROME_VERSION:-unknown}"

  # ── 定位可执行文件 ──────────────────────────────────────────
  local bin_path=""
  if [ -x "${INSTALL_PATH}/opt/google/chrome/google-chrome" ]; then
    bin_path="${INSTALL_PATH}/opt/google/chrome/google-chrome"
  elif [ -x "${INSTALL_PATH}/opt/google/chrome/chrome" ]; then
    bin_path="${INSTALL_PATH}/opt/google/chrome/chrome"
  elif [ -x "${INSTALL_PATH}/usr/bin/chromium" ]; then
    bin_path="${INSTALL_PATH}/usr/bin/chromium"
  elif [ -x "${INSTALL_PATH}/usr/bin/chromium-browser" ]; then
    bin_path="${INSTALL_PATH}/usr/bin/chromium-browser"
  else
    bin_path="$(find "${INSTALL_PATH}" -type f \( -name 'google-chrome*' -o -name 'chromium*' \) -perm -111 2>/dev/null | head -n 1 || true)"
  fi

  if [ -z "${bin_path}" ] || [ ! -x "${bin_path}" ]; then
    echo "Chrome/Chromium binary missing under ${INSTALL_PATH}" >&2
    find "${INSTALL_PATH}" -maxdepth 5 -type f | head -n 60 >&2
    return 1
  fi
  export CHROME_BIN="${bin_path}"
  echo "Chrome binary: ${CHROME_BIN} (version: ${CHROME_VERSION})"

  # ── 运行时数据目录 & 环境持久化 ─────────────────────────────
  mkdir -p "${CHROME_DATA}" /deployment/bin

  write_cont_env CHROME_VERSION "${CHROME_VERSION}"
  write_cont_env CHROME_HOME "${INSTALL_PATH}"
  write_cont_env CHROME_DATA "${CHROME_DATA}"
  write_cont_env CHROME_BIN "${CHROME_BIN}"

  {
    echo "export CHROME_HOME=${INSTALL_PATH}"
    echo "export CHROME_DATA=${CHROME_DATA}"
    echo "export CHROME_BIN=${CHROME_BIN}"
    echo "export CHROME_VERSION=${CHROME_VERSION}"
    echo "export PATH=/deployment/bin:\$PATH"
  } >> /etc/environment
}

initConfig(){
  # ── 启动包装脚本 ────────────────────────────────────────────
  cat > "${INSTALL_PATH}/chrome.sh" <<EOF
#!/bin/bash
export CHROME_HOME="\${CHROME_HOME:-${INSTALL_PATH}}"
export CHROME_DATA="\${CHROME_DATA:-${CHROME_DATA}}"
export CHROME_BIN="\${CHROME_BIN:-${CHROME_BIN}}"

mkdir -p "\${CHROME_DATA}"

# Google Chrome 自带 .so 在 opt/google/chrome 下
if [ -d "\${CHROME_HOME}/opt/google/chrome" ]; then
  export LD_LIBRARY_PATH="\${CHROME_HOME}/opt/google/chrome:\${LD_LIBRARY_PATH:-}"
fi
# Chromium (arm64) 可能有额外 lib 目录
if [ -d "\${CHROME_HOME}/usr/lib" ]; then
  export LD_LIBRARY_PATH="\${CHROME_HOME}/usr/lib:\${LD_LIBRARY_PATH:-}"
  for d in "\${CHROME_HOME}/usr/lib"/*; do
    [ -d "\$d" ] && export LD_LIBRARY_PATH="\$d:\${LD_LIBRARY_PATH}"
  done
fi

exec "\${CHROME_BIN}" \\
  --no-sandbox \\
  --disable-gpu \\
  --disable-dev-shm-usage \\
  --user-data-dir="\${CHROME_DATA}" \\
  \${CHROME_OPTS:-} \\
  "\$@"
EOF
  chmod +x "${INSTALL_PATH}/chrome.sh"
  ln -sfn "${INSTALL_PATH}/chrome.sh" /deployment/bin/chrome

  # ── 桌面菜单 ────────────────────────────────────────────────
  mkdir -p /usr/share/applications
  local icon=""
  icon="$(find "${INSTALL_PATH}/opt/google/chrome" -type f \( -name '*.png' -o -name '*.svg' \) 2>/dev/null | head -n 1 || true)"
  if [ -z "${icon}" ]; then
    icon="$(find "${INSTALL_PATH}/usr/share" -type f \( -name '*chrome*' -o -name '*chromium*' \) \( -name '*.png' -o -name '*.svg' \) 2>/dev/null | head -n 1 || true)"
  fi

  local app_name="Google Chrome"
  if echo "${CHROME_BIN}" | grep -qi chromium; then
    app_name="Chromium"
  fi

  cat > /usr/share/applications/chrome.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${app_name}
Comment=${app_name} Web Browser
Exec=/deployment/bin/chrome
${icon:+Icon=${icon}}
Terminal=false
Categories=Network;WebBrowser;
EOF

  # ── README ──────────────────────────────────────────────────
  cat > "${INSTALL_PATH}/README.md" <<EOF
# ${app_name} layer (COPY-friendly)

App extracted from official .deb under \`${INSTALL_PATH}\`.
Runtime user data: \`${CHROME_DATA}\`.

\`\`\`dockerfile
COPY --from=<chrome-image> /deployment/software/chrome /deployment/software/chrome
COPY --from=<chrome-image> /deployment/bin/chrome /deployment/bin/chrome
\`\`\`

Only user-data after use:
\`\`\`dockerfile
COPY --from=<src> /deployment/software/chrome/data /deployment/software/chrome/data
\`\`\`

Chrome flags（可通过 CHROME_OPTS 环境变量覆盖）:
  --no-sandbox --disable-gpu --disable-dev-shm-usage

容器启动时 s6 会自动拉起 Chrome（依赖 desktop/VNC）。
关闭：-e CHROME_AUTOSTART=0
EOF

  chown -R sarmn:sarmn "${INSTALL_PATH}"
}

initS6Config(){
  # ── s6 自启服务，依赖 desktop/VNC ───────────────────────────
  mkdir -p /etc/s6-overlay/s6-rc.d/chrome/dependencies.d

  cat > /etc/s6-overlay/s6-rc.d/chrome/type <<'EOF'
longrun
EOF

  cat > /etc/s6-overlay/s6-rc.d/chrome/run <<'EOF'
#!/bin/bash
exec s6-setuidgid sarmn /etc/s6-overlay/s6-rc.d/chrome/start.sh
EOF

  cat > /etc/s6-overlay/s6-rc.d/chrome/start.sh <<'EOF'
#!/bin/bash
set -e
# 允许关闭自动启动
if [ "${CHROME_AUTOSTART:-1}" = "0" ] || [ "${CHROME_AUTOSTART:-1}" = "false" ]; then
  echo "CHROME_AUTOSTART disabled; idle"
  exec s6-pause
fi

export HOME=/deployment/accounts/sarmn
export USER=sarmn
export DISPLAY="${DISPLAY:-:1}"

# 等 X / VNC 就绪（最多约 60s）
for i in $(seq 1 60); do
  if [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] 2>/dev/null || [ -e "/tmp/.X11-unix/X${DISPLAY#:}" ]; then
    break
  fi
  sleep 1
done
sleep 2

exec /deployment/bin/chrome
EOF

  cat > /etc/s6-overlay/s6-rc.d/chrome/finish <<'EOF'
#!/bin/bash
pkill -u sarmn -f '[c]hrome' 2>/dev/null || true
pkill -u sarmn -f '[c]hromium' 2>/dev/null || true
exit 0
EOF

  # 等 noVNC/desktop 后再起 GUI
  cat > /etc/s6-overlay/s6-rc.d/chrome/dependencies.d/desktop <<'EOF'
EOF

  cat > /etc/s6-overlay/s6-rc.d/user/contents.d/chrome <<'EOF'
EOF

  chmod 0755 /etc/s6-overlay/s6-rc.d/chrome/run
  chmod 0755 /etc/s6-overlay/s6-rc.d/chrome/start.sh
  chmod 0755 /etc/s6-overlay/s6-rc.d/chrome/finish
  chmod 0644 /etc/s6-overlay/s6-rc.d/chrome/type
  chmod 0644 /etc/s6-overlay/s6-rc.d/chrome/dependencies.d/desktop

  write_cont_env CHROME_AUTOSTART "1"
}

autoExecuteFunc setEnv installDeps installChrome initConfig initS6Config
