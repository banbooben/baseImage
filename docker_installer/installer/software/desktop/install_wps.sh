#!/bin/bash
###
 # Install WPS Office under /deployment/software/wps.
 # Layer layout (COPY-friendly):
 #   /deployment/software/wps/               # 解包后的包内容 (opt/office6)
 #   /deployment/bin/wps                     # launcher (wps/wpp/et)
 #
 # Upstream: https://www.wps.com/download/
 #   amd64 / x86_64: 官方主 CDN（11.1.0.11723.XA），持续更新最新版
 #   arm64 / aarch64: wdl1.cache.wps.cn（11.1.0.9719）
 # 版本通过 WPS_PIN_VERSION 覆盖；下载地址通过 WPS_PKG_URL（或历史变量
 # WPS_DEB_URL / WPS_RPM_URL）覆盖。
 #
 # 发行版差异：
 #   包格式不同（deb 用 `_amd64` 后缀，rpm 用 `-1.x86_64` 后缀），由 setEnv 选；
 #   arm64 的 deb 不含中文 MUI 与字体，需从 amd64 deb 补（见 installWpsMuiAndFonts）；
 #   arm64 的 rpm 本身已带全 zh_CN MUI 与字体，无需补。
###
source /deployment/scripts/common.sh

check_target_arch(){
  ARCH=$(uname -m)
  case $ARCH in
      x86_64|amd64)
          TARGET_ARCH="x86_64"
          ;;
      aarch64|arm64)
          TARGET_ARCH="aarch64"
          ;;
      *)
          echo "WPS Office 不支持架构: $ARCH，跳过安装" >&2
          TARGET_ARCH=""
          ;;
  esac
  export TARGET_ARCH
}

setEnv(){
  check_target_arch
  detect_distro || return 1
  export DEBIAN_FRONTEND=noninteractive
  export INSTALL_PATH=/deployment/software/wps

  # 包扩展名按发行版选；下面的下载地址随扩展名走
  local pkg_ext="deb"
  [ "$DISTRO_FAMILY" = "rpm" ] && pkg_ext="rpm"
  WPS_PKG_EXT="${pkg_ext}"

  local default_url=""
  if [ "${TARGET_ARCH}" = "aarch64" ]; then
    # ARM64 个人版
    WPS_VERSION="${WPS_PIN_VERSION:-11.1.0.9719}"
    if [ "$pkg_ext" = "deb" ]; then
      default_url="https://wdl1.cache.wps.cn/wps/download/ep/Linux2019/9719/wps-office_${WPS_VERSION}_arm64.deb"
    else
      default_url="https://wdl1.cache.wps.cn/wps/download/ep/Linux2019/9719/wps-office-${WPS_VERSION}-1.aarch64.rpm"
    fi
  else
    # amd64：官方主 CDN 最新版
    WPS_VERSION="${WPS_PIN_VERSION:-11.1.0.11723.XA}"
    if [ "$pkg_ext" = "deb" ]; then
      default_url="https://wdl1.pcfg.cache.wpscdn.com/wpsdl/wpsoffice/download/linux/11723/wps-office_${WPS_VERSION}_amd64.deb"
    else
      default_url="https://wdl1.pcfg.cache.wpscdn.com/wpsdl/wpsoffice/download/linux/11723/wps-office-${WPS_VERSION}-1.x86_64.rpm"
    fi
  fi

  # WPS_PKG_URL 优先；WPS_DEB_URL / WPS_RPM_URL 是历史变量，继续兼容
  WPS_PKG_URL="${WPS_PKG_URL:-${WPS_DEB_URL:-${WPS_RPM_URL:-${default_url}}}}"

  export WPS_VERSION WPS_PKG_URL WPS_PKG_EXT
  echo "Using WPS Office ${WPS_VERSION} (${TARGET_ARCH}, ${WPS_PKG_EXT})"
}

installDeps(){
  export DEBIAN_FRONTEND=noninteractive
  pkg_update
  pkg_install \
    ca-certificates wget \
    libqt5gui5 libqt5core5a libqt5widgets5 libqt5dbus5 \
    libxslt1.1 libgl1 libglib2.0-0 libfreetype6 \
    xdg-utils
  pkg_clean
}

installWps(){
  if [ -z "${TARGET_ARCH:-}" ]; then
    echo "当前架构不支持 WPS Office，跳过安装" >&2
    mkdir -p /deployment/software /deployment/bin
    return 0
  fi

  local tmp="/tmp/wps-office-${WPS_VERSION}.${WPS_PKG_EXT}"
  local extract_tmp="/tmp/wps-extract"

  mkdir -p /deployment/software /deployment/bin
  rm -rf "${INSTALL_PATH}" "${extract_tmp}" "${tmp}"
  mkdir -p "${extract_tmp}"

  echo "Downloading WPS Office from ${WPS_PKG_URL}"
  # 该 CDN 会对 curl 默认 UA 返回 403，wget 正常
  wget -q --timeout=300 -O "${tmp}" "${WPS_PKG_URL}" || {
    echo "Failed to download WPS Office from ${WPS_PKG_URL}" >&2
    return 1
  }

  # 解包到软件树，便于整层 COPY（不装进系统路径）
  pkg_extract "${tmp}" "${extract_tmp}" || {
    echo "Failed to extract WPS Office package" >&2
    rm -f "${tmp}"
    return 1
  }
  rm -f "${tmp}"

  mkdir -p "${INSTALL_PATH}"
  if [ -d "${extract_tmp}/opt/kingsoft/wps-office" ]; then
    mv "${extract_tmp}/opt/kingsoft/wps-office" "${INSTALL_PATH}/opt"
  else
    echo "Unexpected package layout:" >&2
    find "${extract_tmp}" -maxdepth 3 -print >&2
    return 1
  fi

  # ── WPS 字体（包内嵌时提取） ──────────────────────────────────
  if [ -d "${extract_tmp}/usr/share/fonts/wps-office" ]; then
    mkdir -p /usr/share/fonts/wps-office
    cp -a "${extract_tmp}/usr/share/fonts/wps-office/." /usr/share/fonts/wps-office/
  fi

  rm -rf "${extract_tmp}"

  # ── ARM64 deb：补中文 MUI 和字体 ─────────────────────────────
  # （rpm 版自带 mui/zh_CN，无需补）
  if [ "${TARGET_ARCH}" = "aarch64" ] && [ "${WPS_PKG_EXT}" = "deb" ]; then
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

# ARM64 deb 不含中文 MUI 和字体，从同版本 amd64 deb 中提取（均为架构无关数据文件）。
# 仅 Debian 系需要：openEuler 的 aarch64 rpm 自带 mui/zh_CN 与 wps 字体。
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
  pkg_extract "${amd64_tmp}" "${amd64_extract}" || {
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

Installed from official WPS download (${WPS_PKG_EXT}) under \`${INSTALL_PATH}\`.

\`\`\`dockerfile
COPY --from=<wps-image> /deployment/software/wps /deployment/software/wps
COPY --from=<wps-image> /deployment/bin/wps /deployment/bin/wps
\`\`\`

Supports amd64 + arm64.
  amd64 / x86_64: 官方主 CDN（最新版，11.1.0.11723.XA）
  arm64 / aarch64: wdl1.cache.wps.cn（11.1.0.9719）
EOF

  chown -R sarmn:sarmn "${INSTALL_PATH}"
}

autoExecuteFunc setEnv installDeps installWps initConfig
