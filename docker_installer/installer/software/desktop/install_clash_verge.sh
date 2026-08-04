#!/bin/bash
###
 # Install Clash Verge Rev under /deployment/software/clash-verge.
 # Layer layout (COPY-friendly):
 #   /deployment/software/clash-verge/          # extracted .deb (usr/bin, usr/lib, ...)
 #   /deployment/software/clash-verge/data/     # XDG config/cache/state (runtime)
 #   /deployment/bin/clash-verge               # launcher
 #
 # Upstream: https://github.com/clash-verge-rev/clash-verge-rev
 # 默认跟随 GitHub latest；仅在需要时覆盖：CLASH_VERGE_PIN_VERSION=2.5.2
###
source /deployment/scripts/common.sh

check_target_arch(){
  ARCH=$(uname -m)
  case $ARCH in
      x86_64|amd64)
          TARGET_ARCH="x86_64"
          DEB_ARCH="amd64"
          ;;
      aarch64|arm64)
          TARGET_ARCH="aarch64"
          DEB_ARCH="arm64"
          ;;
      *)
          echo "未知架构: $ARCH"
          exit 1
          ;;
  esac
  export TARGET_ARCH DEB_ARCH
  echo "目标架构: $TARGET_ARCH (deb=${DEB_ARCH})"
}

setEnv(){
  check_target_arch
  export DEBIAN_FRONTEND=noninteractive
  export INSTALL_PATH=/deployment/software/clash-verge
  export CLASH_VERGE_DATA="${INSTALL_PATH}/data"
  # Optional mirror prefix, e.g. https://ghproxy.net/
  export GITHUB_PROXY="${GITHUB_PROXY:-}"

  # 默认跟随 upstream latest；设置 CLASH_VERGE_PIN_VERSION 才钉死（不要带 v 前缀）
  CLASH_VERGE_VERSION="$(resolve_github_latest_tag clash-verge-rev/clash-verge-rev CLASH_VERGE_PIN_VERSION)" || return 1
  export CLASH_VERGE_VERSION

  echo "Using Clash Verge Rev ${CLASH_VERGE_VERSION} (${TARGET_ARCH})"
}

installDeps(){
  # Tauri / WebKit GTK 运行时；noble-desktop 已有部分 gtk/X，缺啥补啥
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates wget \
    libwebkit2gtk-4.1-0 \
    libgtk-3-0 \
    libayatana-appindicator3-1 \
    librsvg2-2 \
    libssl3t64 \
    openssl \
    xdg-utils \
    || apt-get install -y --no-install-recommends \
      ca-certificates wget \
      libwebkit2gtk-4.1-0 \
      libgtk-3-0 \
      libayatana-appindicator3-1 \
      librsvg2-2 \
      libssl3 \
      openssl \
      xdg-utils
  apt-get clean -y
  rm -rf /var/lib/apt/lists/*
}

github_release_url(){
  local path="$1"
  local base="https://github.com/${path}"
  if [ -n "${GITHUB_PROXY}" ]; then
    echo "${GITHUB_PROXY%/}/${base}"
  else
    echo "${base}"
  fi
}

installClashVerge(){
  local ver="${CLASH_VERGE_VERSION}"
  local archive="Clash.Verge_${ver}_${DEB_ARCH}.deb"
  local url
  url="$(github_release_url "clash-verge-rev/clash-verge-rev/releases/download/v${ver}/${archive}")"
  local tmp="/tmp/${archive}"
  local extract_tmp="/tmp/clash-verge-extract"

  mkdir -p /deployment/software /deployment/bin
  rm -rf "${INSTALL_PATH}" "${extract_tmp}"
  mkdir -p "${extract_tmp}"

  echo "download Clash Verge ${archive}"
  wget -q --timeout=180 -O "${tmp}" "${url}" || {
    echo "Failed to download ${url}" >&2
    return 1
  }

  # 解压 deb 到软件树，便于整层 COPY（不用 dpkg 污染系统路径）
  dpkg-deb -x "${tmp}" "${extract_tmp}"
  rm -f "${tmp}"

  mkdir -p "${INSTALL_PATH}"
  # deb 内容通常为 usr/bin、usr/lib、usr/share
  if [ -d "${extract_tmp}/usr" ]; then
    mv "${extract_tmp}/usr" "${INSTALL_PATH}/usr"
  else
    echo "Unexpected deb layout:" >&2
    find "${extract_tmp}" -maxdepth 3 -print >&2
    return 1
  fi
  rm -rf "${extract_tmp}"

  # 定位可执行文件
  local bin_path=""
  if [ -x "${INSTALL_PATH}/usr/bin/clash-verge" ]; then
    bin_path="${INSTALL_PATH}/usr/bin/clash-verge"
  else
    bin_path="$(find "${INSTALL_PATH}/usr" -type f -name 'clash-verge' -perm -111 2>/dev/null | head -n 1 || true)"
  fi
  if [ -z "${bin_path}" ] || [ ! -x "${bin_path}" ]; then
    echo "clash-verge binary missing under ${INSTALL_PATH}" >&2
    find "${INSTALL_PATH}" -maxdepth 4 -type f | head -n 50 >&2
    return 1
  fi
  export CLASH_VERGE_BIN="${bin_path}"

  mkdir -p "${CLASH_VERGE_DATA}" /deployment/bin

  write_cont_env CLASH_VERGE_VERSION "${CLASH_VERGE_VERSION}"
  write_cont_env CLASH_VERGE_HOME "${INSTALL_PATH}"
  write_cont_env CLASH_VERGE_DATA "${CLASH_VERGE_DATA}"
  write_cont_env CLASH_VERGE_BIN "${CLASH_VERGE_BIN}"

  {
    echo "export CLASH_VERGE_HOME=${INSTALL_PATH}"
    echo "export CLASH_VERGE_DATA=${CLASH_VERGE_DATA}"
    echo "export CLASH_VERGE_BIN=${CLASH_VERGE_BIN}"
    echo "export CLASH_VERGE_VERSION=${CLASH_VERGE_VERSION}"
    echo "export PATH=/deployment/bin:\$PATH"
  } >> /etc/environment
}

initConfig(){
  # 启动包装：配置/缓存落到软件树 data/，方便 COPY 迁移
  cat > "${INSTALL_PATH}/clash-verge.sh" <<EOF
#!/bin/bash
export CLASH_VERGE_HOME="${INSTALL_PATH}"
export CLASH_VERGE_DATA="\${CLASH_VERGE_DATA:-${CLASH_VERGE_DATA}}"
export CLASH_VERGE_BIN="\${CLASH_VERGE_BIN:-${CLASH_VERGE_BIN}}"
mkdir -p "\${CLASH_VERGE_DATA}/config" "\${CLASH_VERGE_DATA}/share" \
         "\${CLASH_VERGE_DATA}/state" "\${CLASH_VERGE_DATA}/cache"
export XDG_CONFIG_HOME="\${CLASH_VERGE_DATA}/config"
export XDG_DATA_HOME="\${CLASH_VERGE_DATA}/share"
export XDG_STATE_HOME="\${CLASH_VERGE_DATA}/state"
export XDG_CACHE_HOME="\${CLASH_VERGE_DATA}/cache"
# 部分打包把 .so 放在 usr/lib 下
if [ -d "\${CLASH_VERGE_HOME}/usr/lib" ]; then
  export LD_LIBRARY_PATH="\${CLASH_VERGE_HOME}/usr/lib:\${LD_LIBRARY_PATH:-}"
  for d in "\${CLASH_VERGE_HOME}/usr/lib"/*; do
    [ -d "\$d" ] && export LD_LIBRARY_PATH="\$d:\${LD_LIBRARY_PATH}"
  done
fi
exec "\${CLASH_VERGE_BIN}" "\$@"
EOF
  chmod +x "${INSTALL_PATH}/clash-verge.sh"
  ln -sfn "${INSTALL_PATH}/clash-verge.sh" /deployment/bin/clash-verge

  # 桌面菜单
  mkdir -p /usr/share/applications
  local icon=""
  icon="$(find "${INSTALL_PATH}/usr/share" -type f \( -name '*.png' -o -name '*.svg' \) 2>/dev/null | head -n 1 || true)"
  cat > /usr/share/applications/clash-verge.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Clash Verge
Comment=Clash Verge Rev GUI proxy client
Exec=/deployment/bin/clash-verge
${icon:+Icon=${icon}}
Terminal=false
Categories=Network;
EOF

  mkdir -p "${CLASH_VERGE_DATA}/config" "${CLASH_VERGE_DATA}/share" \
           "${CLASH_VERGE_DATA}/state" "${CLASH_VERGE_DATA}/cache"
  cat > "${INSTALL_PATH}/README.md" <<EOF
# Clash Verge Rev layer (COPY-friendly)

App extracted from official .deb under \\\`${INSTALL_PATH}\\\`.
Runtime XDG data: \\\`${CLASH_VERGE_DATA}\\\`.

\`\`\`dockerfile
COPY --from=<clash-verge-image> /deployment/software/clash-verge /deployment/software/clash-verge
COPY --from=<clash-verge-image> /deployment/bin/clash-verge /deployment/bin/clash-verge
\`\`\`

Only config/cache after use:
\`\`\`dockerfile
COPY --from=<src> /deployment/software/clash-verge/data /deployment/software/clash-verge/data
\`\`\`

TUN / 系统代理在容器内通常还需 --cap-add=NET_ADMIN --device /dev/net/tun 等权限。

容器启动时 s6 会自动拉起 Clash Verge（依赖 desktop/VNC）。
关闭：-e CLASH_VERGE_AUTOSTART=0
EOF

  chown -R sarmn:sarmn "${INSTALL_PATH}"
}

initS6Config(){
  # 容器启动后由 s6 自动拉起 GUI（依赖 desktop/VNC，DISPLAY=:1）
  # 关闭自动启动：环境变量 CLASH_VERGE_AUTOSTART=0
  mkdir -p /etc/s6-overlay/s6-rc.d/clash-verge/dependencies.d

  cat > /etc/s6-overlay/s6-rc.d/clash-verge/type <<'EOF'
longrun
EOF

  cat > /etc/s6-overlay/s6-rc.d/clash-verge/run <<'EOF'
#!/bin/bash
# 写入全局代理环境变量（容器桌面无 D-Bus 系统代理，用 env 代替）
# 端口 7891=HTTP, 7890=SOCKS5 — 对应 mihomo 内核默认监听端口
mkdir -p /etc/environments
cat > /etc/environments/proxy-clash <<'PROXY'
HTTP_PROXY=http://127.0.0.1:7891
HTTPS_PROXY=http://127.0.0.1:7891
ALL_PROXY=socks5://127.0.0.1:7890
NO_PROXY=localhost,127.0.0.1,::1
PROXY
# 如果 /etc/environment 没有这些变量则追加（避免重复堆叠）
while IFS='=' read -r key _; do
  grep -q "^${key}=" /etc/environment 2>/dev/null || \
    grep "^${key}=" /etc/environments/proxy-clash >> /etc/environment
done < /etc/environments/proxy-clash
exec s6-setuidgid sarmn /etc/s6-overlay/s6-rc.d/clash-verge/start.sh
EOF

  cat > /etc/s6-overlay/s6-rc.d/clash-verge/start.sh <<'EOF'
#!/bin/bash
set -e
# 允许关闭自动启动
if [ "${CLASH_VERGE_AUTOSTART:-1}" = "0" ] || [ "${CLASH_VERGE_AUTOSTART:-1}" = "false" ]; then
  echo "CLASH_VERGE_AUTOSTART disabled; idle"
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

# 读取 D-Bus session bus 地址（VNC xstartup 写入），Clash Verge 系统代理需要
if [ -f /tmp/.dbus-session-address ]; then
  export DBUS_SESSION_BUS_ADDRESS="$(cat /tmp/.dbus-session-address)"
  echo "Clash Verge: D-Bus session address loaded"
else
  echo "Clash Verge: WARNING - D-Bus session address not found, system proxy unavailable" >&2
fi

exec /deployment/bin/clash-verge
EOF

  cat > /etc/s6-overlay/s6-rc.d/clash-verge/finish <<'EOF'
#!/bin/bash
pkill -u sarmn -f '[c]lash-verge' 2>/dev/null || true
exit 0
EOF

  # 等 noVNC/desktop（其已依赖 vnc）后再起 GUI
  cat > /etc/s6-overlay/s6-rc.d/clash-verge/dependencies.d/desktop <<'EOF'
EOF

  cat > /etc/s6-overlay/s6-rc.d/user/contents.d/clash-verge <<'EOF'
EOF

  chmod 0755 /etc/s6-overlay/s6-rc.d/clash-verge/run
  chmod 0755 /etc/s6-overlay/s6-rc.d/clash-verge/start.sh
  chmod 0755 /etc/s6-overlay/s6-rc.d/clash-verge/finish
  chmod 0644 /etc/s6-overlay/s6-rc.d/clash-verge/type
  chmod 0644 /etc/s6-overlay/s6-rc.d/clash-verge/dependencies.d/desktop

  write_cont_env CLASH_VERGE_AUTOSTART "1"
}

autoExecuteFunc setEnv installDeps installClashVerge initConfig initS6Config
