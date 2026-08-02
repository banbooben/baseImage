#!/bin/bash
###
 # Install Chromium under /deployment/software/chrome.
 # Layer layout (COPY-friendly):
 #   /deployment/software/chrome/               # usr/bin/, usr/lib/, usr/share/
 #   /deployment/software/chrome/data/          # user-data-dir (runtime)
 #   /deployment/bin/chrome                     # launcher
 #
 # Upstream: ppa:xtradeb/apps (amd64 + arm64)
 # Chromium apt 安装统一 amd64/arm64，无需架构差异分支。
###
source /deployment/scripts/common.sh

setEnv(){
  export DEBIAN_FRONTEND=noninteractive
  export INSTALL_PATH=/deployment/software/chrome
  export CHROME_DATA="${INSTALL_PATH}/data"

  echo "Chromium (ppa:xtradeb/apps)"
}

installDeps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates wget software-properties-common \
    libgtk-3-0 libx11-6 libxcb1 libxtst6 libxfixes3 \
    libnss3 libnspr4 libgbm1 \
    libasound2t64 \
    libatk-bridge2.0-0 libatspi2.0-0 \
    libcups2 libdrm2 libxcomposite1 libxdamage1 libxrandr2 \
    libxkbcommon0 libpango-1.0-0 libcairo2 \
    fonts-liberation fonts-noto-cjk fonts-noto-color-emoji \
    xdg-utils
  apt-get clean -y
  rm -rf /var/lib/apt/lists/*
}

installChrome(){
  mkdir -p /deployment/software /deployment/bin
  rm -rf "${INSTALL_PATH}"

  # ── 添加 Chromium PPA（amd64 + arm64 统一）────────────────────
  add-apt-repository ppa:xtradeb/apps -y
  apt-get update
  apt-get install -y --no-install-recommends \
    chromium \
    libva-drm2 libva-x11-2 libva-wayland2

  # ── 复制到 INSTALL_PATH，保持 COPY-friendly 布局 ─────────────
  local multiarch
  multiarch="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || echo "x86_64-linux-gnu")"

  mkdir -p "${INSTALL_PATH}/usr/bin" \
           "${INSTALL_PATH}/usr/lib/${multiarch}" \
           "${INSTALL_PATH}/usr/share"

  # 二进制（PPA 包名为 chromium，二进制路径 /usr/bin/chromium）
  if [ -x /usr/bin/chromium ]; then
    cp -a /usr/bin/chromium "${INSTALL_PATH}/usr/bin/"
  elif [ -x /usr/bin/chromium-browser ]; then
    cp -a /usr/bin/chromium-browser "${INSTALL_PATH}/usr/bin/"
  fi

  # Chromium 相关的 .so
  if [ -d "/usr/lib/${multiarch}" ]; then
    cp -an "/usr/lib/${multiarch}"/libchromium* "${INSTALL_PATH}/usr/lib/${multiarch}/" 2>/dev/null || true
  fi

  # 资源文件
  for src_dir in /usr/share/chromium /usr/share/chromium-browser; do
    if [ -d "${src_dir}" ]; then
      cp -a "${src_dir}" "${INSTALL_PATH}/usr/share/" 2>/dev/null || true
      break
    fi
  done

  CHROME_VERSION="$(chromium --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")"
  apt-get clean -y
  export CHROME_VERSION

  echo "Chromium version: ${CHROME_VERSION}"

  # ── 定位可执行文件 ──────────────────────────────────────────
  local bin_path=""
  if [ -x "${INSTALL_PATH}/usr/bin/chromium" ]; then
    bin_path="${INSTALL_PATH}/usr/bin/chromium"
  elif [ -x "${INSTALL_PATH}/usr/bin/chromium-browser" ]; then
    bin_path="${INSTALL_PATH}/usr/bin/chromium-browser"
  else
    bin_path="$(find "${INSTALL_PATH}/usr/bin" -type f -name 'chromium*' -perm -111 2>/dev/null | head -n 1 || true)"
  fi

  if [ -z "${bin_path}" ] || [ ! -x "${bin_path}" ]; then
    echo "Chromium binary missing under ${INSTALL_PATH}" >&2
    find "${INSTALL_PATH}" -maxdepth 5 -type f | head -n 60 >&2
    return 1
  fi
  export CHROME_BIN="${bin_path}"
  echo "Chromium binary: ${CHROME_BIN}"

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

# 系统库路径（ALSA / GTK / CUPS 等）
ARCH_LIBDIR="/usr/lib/\$(uname -m | sed 's/x86_64/x86_64-linux-gnu/;s/aarch64/aarch64-linux-gnu/')"
export LD_LIBRARY_PATH="\${LD_LIBRARY_PATH:-}:\${ARCH_LIBDIR}:/usr/lib"

# Chromium 额外 lib 目录
if [ -d "\${CHROME_HOME}/usr/lib" ]; then
  export LD_LIBRARY_PATH="\${LD_LIBRARY_PATH}:\${CHROME_HOME}/usr/lib"
  for d in "\${CHROME_HOME}/usr/lib"/*; do
    [ -d "\$d" ] && export LD_LIBRARY_PATH="\${LD_LIBRARY_PATH}:\$d"
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
  icon="$(find "${INSTALL_PATH}/usr/share" -type f \( -name '*chromium*' -o -name '*chrome*' \) \( -name '*.png' -o -name '*.svg' \) 2>/dev/null | head -n 1 || true)"

  cat > /usr/share/applications/chrome.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Chromium
Comment=Chromium Web Browser
Exec=/deployment/bin/chrome
${icon:+Icon=${icon}}
Terminal=false
Categories=Network;WebBrowser;
EOF

  # ── README ──────────────────────────────────────────────────
  cat > "${INSTALL_PATH}/README.md" <<EOF
# Chromium layer (COPY-friendly)

Installed from ppa:xtradeb/apps under \`${INSTALL_PATH}\`.
Runtime user data: \`${CHROME_DATA}\`.

\`\`\`dockerfile
COPY --from=<chrome-image> /deployment/software/chrome /deployment/software/chrome
COPY --from=<chrome-image> /deployment/bin/chrome /deployment/bin/chrome
\`\`\`

Only user-data after use:
\`\`\`dockerfile
COPY --from=<src> /deployment/software/chrome/data /deployment/software/chrome/data
\`\`\`

Chromium flags（可通过 CHROME_OPTS 环境变量覆盖）:
  --no-sandbox --disable-gpu --disable-dev-shm-usage

容器启动时 s6 会自动拉起 Chromium（依赖 desktop/VNC）。
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
