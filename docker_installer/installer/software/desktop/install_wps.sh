#!/bin/bash
###
 # Install WPS Office under /deployment/software/wps.
 # Layer layout (COPY-friendly):
 #   /deployment/software/wps/               # extracted .deb (opt/kingsoft/wps-office)
 #   /deployment/bin/wps                     # launcher (wps/wpp/et)
 #
 # Upstream: https://www.wps.com/download/
 #   amd64: 官方主 CDN，持续更新最新版
 #   arm64: wdl1.cache.wps.cn（11.1.0.9719）
 # 版本通过 WPS_PIN_VERSION 或 WPS_DEB_URL 覆盖。
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
          echo "WPS Office 不支持架构: $ARCH，跳过安装" >&2
          TARGET_ARCH=""
          DEB_ARCH=""
          ;;
  esac
  export TARGET_ARCH DEB_ARCH
}

setEnv(){
  check_target_arch
  export DEBIAN_FRONTEND=noninteractive
  export INSTALL_PATH=/deployment/software/wps

  if [ "${DEB_ARCH}" = "arm64" ]; then
    # ARM64 个人版
    WPS_VERSION="${WPS_PIN_VERSION:-11.1.0.9719}"
    WPS_DEB_URL="${WPS_DEB_URL:-https://wdl1.cache.wps.cn/wps/download/ep/Linux2019/9719/wps-office_${WPS_VERSION}_arm64.deb}"
  else
    # amd64：官方主 CDN 最新版
    WPS_VERSION="${WPS_PIN_VERSION:-11.1.0.11723.XA}"
    WPS_DEB_URL="${WPS_DEB_URL:-https://wdl1.pcfg.cache.wpscdn.com/wpsdl/wpsoffice/download/linux/11723/wps-office_${WPS_VERSION}_amd64.deb}"
  fi

  export WPS_VERSION WPS_DEB_URL
  echo "Using WPS Office ${WPS_VERSION} (${DEB_ARCH})"
}

installDeps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates wget \
    libqt5gui5 libqt5core5a libqt5widgets5 libqt5dbus5 \
    libxslt1.1 libgl1 libglib2.0-0 libfreetype6 \
    xdg-utils
  apt-get clean -y
  rm -rf /var/lib/apt/lists/*
}

installWps(){
  if [ -z "${TARGET_ARCH:-}" ] || [ -z "${DEB_ARCH:-}" ]; then
    echo "当前架构不支持 WPS Office，跳过安装" >&2
    mkdir -p /deployment/software /deployment/bin
    return 0
  fi

  local tmp="/tmp/wps-office_${WPS_VERSION}_${DEB_ARCH}.deb"
  local extract_tmp="/tmp/wps-extract"

  mkdir -p /deployment/software /deployment/bin
  rm -rf "${INSTALL_PATH}" "${extract_tmp}"
  mkdir -p "${extract_tmp}"

  echo "Downloading WPS Office from ${WPS_DEB_URL}"
  wget -q --timeout=300 -O "${tmp}" "${WPS_DEB_URL}" || {
    echo "Failed to download WPS Office from ${WPS_DEB_URL}" >&2
    return 1
  }

  # 解压 deb 到软件树，便于整层 COPY
  dpkg-deb -x "${tmp}" "${extract_tmp}"
  rm -f "${tmp}"

  mkdir -p "${INSTALL_PATH}"
  if [ -d "${extract_tmp}/opt/kingsoft/wps-office" ]; then
    mv "${extract_tmp}/opt/kingsoft/wps-office" "${INSTALL_PATH}/opt"
  else
    echo "Unexpected deb layout:" >&2
    find "${extract_tmp}" -maxdepth 3 -print >&2
    return 1
  fi

  # ── WPS 字体（deb 内嵌时提取） ────────────────────────────────
  if [ -d "${extract_tmp}/usr/share/fonts/wps-office" ]; then
    mkdir -p /usr/share/fonts/wps-office
    cp -a "${extract_tmp}/usr/share/fonts/wps-office/." /usr/share/fonts/wps-office/
  fi

  rm -rf "${extract_tmp}"

  # ── ARM64: 从同版本 amd64 deb 提取中文 MUI 和字体 ────────────
  if [ "${DEB_ARCH}" = "arm64" ]; then
    installWpsMuiAndFonts
  fi

  # ── 定位可执行文件 ──────────────────────────────────────────
  local wps_bin="${INSTALL_PATH}/opt/office6/wps"
  local wpp_bin="${INSTALL_PATH}/opt/office6/wpp"
  local et_bin="${INSTALL_PATH}/opt/office6/et"

  if [ ! -x "${wps_bin}" ]; then
    echo "WPS binary missing: ${wps_bin}" >&2
    find "${INSTALL_PATH}" -maxdepth 5 -type f -perm -111 | head -n 30 >&2
    return 1
  fi

  export WPS_BIN="${wps_bin}"
  export WPP_BIN="${wpp_bin}"
  export ET_BIN="${et_bin}"

  # ── 环境持久化 ─────────────────────────────────────────────
  write_cont_env WPS_VERSION "${WPS_VERSION}"
  write_cont_env WPS_HOME "${INSTALL_PATH}"
  write_cont_env WPS_BIN "${WPS_BIN}"
}

# ARM64 deb 不含中文 MUI 和字体，从同版本 amd64 deb 中提取（均为架构无关数据文件）
installWpsMuiAndFonts(){
  local amd64_url="https://wdl1.cache.wps.cn/wps/download/ep/Linux2019/9719/wps-office_${WPS_VERSION}_amd64.deb"
  local amd64_tmp="/tmp/wps-office_${WPS_VERSION}_amd64.deb"
  local amd64_extract="/tmp/wps-amd64-extract"

  # 如果 MUI 已存在则跳过
  if [ -d "${INSTALL_PATH}/opt/office6/mui/zh_CN" ]; then
    echo "WPS zh_CN MUI already present, skipping extraction"
    return 0
  fi

  echo "Downloading WPS amd64 package for MUI/fonts extraction..."
  wget -q --timeout=300 -O "${amd64_tmp}" "${amd64_url}" || {
    echo "WARNING: Failed to download amd64 WPS for MUI/fonts, Chinese UI may not be available" >&2
    return 0
  }

  rm -rf "${amd64_extract}"
  mkdir -p "${amd64_extract}"
  dpkg-deb -x "${amd64_tmp}" "${amd64_extract}" || {
    echo "WARNING: Failed to extract amd64 WPS for MUI/fonts" >&2
    rm -rf "${amd64_tmp}" "${amd64_extract}"
    return 0
  }
  rm -f "${amd64_tmp}"

  # 复制中文 MUI（架构无关的 .qm/.rcc 资源文件）
  if [ -d "${amd64_extract}/opt/kingsoft/wps-office/office6/mui/zh_CN" ]; then
    cp -a "${amd64_extract}/opt/kingsoft/wps-office/office6/mui/zh_CN" "${INSTALL_PATH}/opt/office6/mui/"
    echo "WPS zh_CN MUI installed"
  fi

  # 复制 WPS 字体（架构无关）
  if [ -d "${amd64_extract}/usr/share/fonts/wps-office" ]; then
    mkdir -p /usr/share/fonts/wps-office
    cp -a "${amd64_extract}/usr/share/fonts/wps-office/." /usr/share/fonts/wps-office/
    echo "WPS fonts installed"
  fi

  rm -rf "${amd64_extract}"
}

initConfig(){
  # ── 启动包装脚本 ────────────────────────────────────────────
  cat > "${INSTALL_PATH}/wps.sh" <<'LAUNCHER'
#!/bin/bash
WPS_HOME="${WPS_HOME:-/deployment/software/wps}"
WPS_APP="${1:-wps}"
case "$WPS_APP" in
  wpp|et|pdf) ;;
  *) WPS_APP="wps" ;;
esac
export LD_LIBRARY_PATH="${WPS_HOME}/opt/office6:${LD_LIBRARY_PATH:-}"
exec "${WPS_HOME}/opt/office6/${WPS_APP}" "$@"
LAUNCHER
  chmod +x "${INSTALL_PATH}/wps.sh"

  # 桌面链接：wps / wpp / et
  for app in wps wpp et; do
    ln -sfn "${INSTALL_PATH}/wps.sh" "/deployment/bin/${app}"
  done

  # ── 桌面菜单 ────────────────────────────────────────────────
  mkdir -p /usr/share/applications
  local icon_dir="${INSTALL_PATH}/opt/office6"
  cat > /usr/share/applications/wps.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=WPS Writer
Comment=WPS Office Word Processor
Exec=/deployment/bin/wps
Icon=${icon_dir}/wpsicon.png
Terminal=false
Categories=Office;WordProcessor;
EOF

  cat > /usr/share/applications/wpp.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=WPS Presentation
Comment=WPS Office Presentation
Exec=/deployment/bin/wpp
Icon=${icon_dir}/wppicon.png
Terminal=false
Categories=Office;Presentation;
EOF

  cat > /usr/share/applications/et.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=WPS Spreadsheets
Comment=WPS Office Spreadsheet
Exec=/deployment/bin/et
Icon=${icon_dir}/eticon.png
Terminal=false
Categories=Office;Spreadsheet;
EOF

  # ── README ──────────────────────────────────────────────────
  cat > "${INSTALL_PATH}/README.md" <<EOF
# WPS Office layer (COPY-friendly)

Installed from official WPS download under \`${INSTALL_PATH}\`.

\`\`\`dockerfile
COPY --from=<wps-image> /deployment/software/wps /deployment/software/wps
COPY --from=<wps-image> /deployment/bin/wps /deployment/bin/wps
\`\`\`

Supports amd64 + arm64.
  amd64: 官方主 CDN（最新版）
  arm64: wdl1.cache.wps.cn（11.1.0.9719）
EOF

  chown -R sarmn:sarmn "${INSTALL_PATH}"
}

autoExecuteFunc setEnv installDeps installWps initConfig
