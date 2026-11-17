#!/bin/bash
###
 # Install Apifox desktop client under /deployment/software/apifox.
 # Layer layout (COPY-friendly):
 #   /deployment/software/apifox/          # AppImage 解包后的 squashfs-root 内容
 #   /deployment/software/apifox/data/     # Electron user-data
 #   /deployment/bin/apifox                # launcher
 #
 # Upstream: https://apifox.com/（官方只提供 AppImage，打包在 zip 里）
 #   阿里云 OSS CDN（本仓库默认，国内可直连）：
 #     amd64: https://file-assets-cdn.oss-cn-hangzhou.aliyuncs.com/download/Apifox-linux-latest.zip
 #     arm64: https://file-assets-cdn.oss-cn-hangzhou.aliyuncs.com/download/Apifox-linux-arm64-latest.zip
 #   官方站点（部分地区会返回 JS 下载验证页，作为回退源）：
 #     amd64: https://file-assets.apifox.com/download/Apifox-linux-latest.zip
 #     arm64: https://file-assets.apifox.com/download/Apifox-linux-arm64-latest.zip
 #
 # 构建期用 AppImage 自带的 --appimage-extract 解包，运行期不需要 FUSE，
 # 也避免每次启动都解压 800MB。
###
source /deployment/scripts/common.sh

check_target_arch(){
  ARCH=$(uname -m)
  case $ARCH in
      x86_64|amd64)
          TARGET_ARCH="linux"
          ;;
      aarch64|arm64)
          TARGET_ARCH="linux-arm64"
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
  export INSTALL_PATH=/deployment/software/apifox
  export APIFOX_DATA="${INSTALL_PATH}/data"

  # 官方只有 -latest 链接，没有版本化 URL；需要固定版本时用
  # APIFOX_DOWNLOAD_URL 指向自建/镜像的 zip。
  # 官方站点在部分网络下会返回「Apifox 下载验证」HTML（HTTP 200），因此默认走
  # 阿里云 OSS CDN，并在拿到非 zip 内容时自动回退到官方站点。
  export APIFOX_DOWNLOAD_URL="${APIFOX_DOWNLOAD_URL:-https://file-assets-cdn.oss-cn-hangzhou.aliyuncs.com/download/Apifox-${TARGET_ARCH}-latest.zip}"
  export APIFOX_DOWNLOAD_URL_FALLBACK="${APIFOX_DOWNLOAD_URL_FALLBACK:-https://file-assets.apifox.com/download/Apifox-${TARGET_ARCH}-latest.zip}"

  echo "Using Apifox from ${APIFOX_DOWNLOAD_URL}"
}

installDeps(){
  # base-desktop 已有 Xfce/GTK 基础；补齐 Electron/AppImage 运行期实际依赖。
  # 包名按 Debian 习惯书写，common.sh 的 map_packages 会翻译成 rpm 名。
  export DEBIAN_FRONTEND=noninteractive
  pkg_update
  pkg_install \
    ca-certificates wget unzip \
    libgtk-3-0 libx11-6 libxcb1 libxtst6 \
    libnss3 libnspr4 libgbm1 libasound2t64 \
    libatk-bridge2.0-0 libatspi2.0-0 \
    libcups2 libdrm2 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libxkbcommon0 libpango-1.0-0 libcairo2 libexpat1 \
    libsecret-1-0 libnotify4 xdg-utils
  pkg_clean
}

downloadArchive(){
  local dest="$1" url
  for url in "${APIFOX_DOWNLOAD_URL}" "${APIFOX_DOWNLOAD_URL_FALLBACK}"; do
    [ -n "${url}" ] || continue
    echo "Downloading Apifox from ${url}"
    # 校验 zip 魔数：CDN 的下载验证页同样是 HTTP 200，wget 不会报错
    if wget -q --timeout=600 -O "${dest}" "${url}" && [ "$(head -c 2 "${dest}" 2>/dev/null)" = "PK" ]; then
      return 0
    fi
    echo "下载失败或内容不是 zip（可能是下载验证页），尝试下一个源" >&2
    rm -f "${dest}"
  done
  return 1
}

installApifox(){
  local zip="/tmp/apifox.zip"
  local work="/tmp/apifox-extract"

  mkdir -p /deployment/software /deployment/bin
  rm -rf "${work}" "${INSTALL_PATH}"
  mkdir -p "${work}"

  downloadArchive "${zip}" || {
    echo "Failed to download Apifox zip" >&2
    return 1
  }

  unzip -q "${zip}" -d "${work}" || {
    echo "Failed to unzip ${zip}" >&2
    return 1
  }
  rm -f "${zip}"

  local appimage
  appimage="$(find "${work}" -maxdepth 1 -type f -name '*.AppImage' | head -n 1 || true)"
  if [ -z "${appimage}" ]; then
    echo "AppImage missing in downloaded archive:" >&2
    find "${work}" -maxdepth 2 -print >&2
    return 1
  fi

  # --appimage-extract 不需要 FUSE，输出到当前目录的 squashfs-root
  chmod +x "${appimage}"
  ( cd "${work}" && "${appimage}" --appimage-extract >/dev/null ) || {
    echo "AppImage extraction failed" >&2
    return 1
  }

  local root="${work}/squashfs-root"
  if [ ! -x "${root}/apifox" ] || [ ! -x "${root}/AppRun" ]; then
    echo "Unexpected AppImage layout under ${root}" >&2
    ls -la "${root}" >&2
    return 1
  fi

  # 保留 squashfs-root 的完整目录结构（AppRun 依赖相对的 usr/lib、resources）
  mkdir -p "${INSTALL_PATH}" "${APIFOX_DATA}"
  cp -a "${root}/." "${INSTALL_PATH}/"

  # 版本号写在 AppImage 自带的 desktop 文件里，没有独立的 version 接口
  local version
  version="$(sed -n 's/^X-AppImage-Version=//p' "${INSTALL_PATH}/apifox.desktop" 2>/dev/null | head -n 1)"
  [ -n "${version}" ] || version="unknown"
  export APIFOX_VERSION="${version}"

  rm -rf "${work}"

  echo "Apifox version: ${APIFOX_VERSION} (${TARGET_ARCH})"

  write_cont_env APIFOX_VERSION "${APIFOX_VERSION}"
  write_cont_env APIFOX_HOME "${INSTALL_PATH}"
  write_cont_env APIFOX_DATA "${APIFOX_DATA}"

  {
    echo "export APIFOX_HOME=${INSTALL_PATH}"
    echo "export APIFOX_DATA=${APIFOX_DATA}"
    echo "export APIFOX_VERSION=${APIFOX_VERSION}"
    echo "export PATH=/deployment/bin:\$PATH"
  } >> /etc/environment
}

initConfig(){
  # ── 启动包装脚本 ────────────────────────────────────────────
  cat > "${INSTALL_PATH}/apifox.sh" <<EOF
#!/bin/bash
export APIFOX_HOME="\${APIFOX_HOME:-${INSTALL_PATH}}"
export APIFOX_DATA="\${APIFOX_DATA:-${APIFOX_DATA}}"
# 直接运行解包后的 AppRun 时没有 AppImage runtime 帮忙设置 APPDIR；不显式导出，
# AppRun 的兜底探测会因首参数不是文件而把 APPDIR 算成空，导致找不到 apifox。
export APPDIR="\${APIFOX_HOME}"

mkdir -p "\${APIFOX_DATA}"

# 容器内无硬件 GPU：关闭 GPU 加速；/dev/shm 通常很小，禁用其使用。
# --no-sandbox 与 AppImage 自带 desktop 文件一致（容器内 chrome-sandbox
# 的 setuid 不可靠，且桌面会话以 sam 非 root 运行）。
exec "\${APIFOX_HOME}/AppRun" \\
  --no-sandbox \\
  --disable-gpu \\
  --disable-dev-shm-usage \\
  --user-data-dir="\${APIFOX_DATA}/profile" \\
  "\$@"
EOF
  chmod +x "${INSTALL_PATH}/apifox.sh"
  ln -sfn "${INSTALL_PATH}/apifox.sh" /deployment/bin/apifox

  # ── 桌面菜单 ────────────────────────────────────────────────
  mkdir -p /usr/share/applications
  local icon=""
  [ -f "${INSTALL_PATH}/apifox.png" ] && icon="${INSTALL_PATH}/apifox.png"

  cat > /usr/share/applications/apifox.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Apifox
Comment=API 文档、调试、Mock 与自动化测试
Exec=/deployment/bin/apifox %U
${icon:+Icon=${icon}}
Terminal=false
Categories=Development;
StartupWMClass=Apifox
EOF

  # ── README ──────────────────────────────────────────────────
  cat > "${INSTALL_PATH}/README.md" <<EOF
# Apifox layer (COPY-friendly)

Installed from the official Linux AppImage under \`${INSTALL_PATH}\`.
Build-time extraction means no FUSE is required at runtime.

\`\`\`dockerfile
COPY --from=<apifox-image> /deployment/software/apifox /deployment/software/apifox
COPY --from=<apifox-image> /deployment/bin/apifox /deployment/bin/apifox
COPY --from=<apifox-image> /usr/share/applications/apifox.desktop /usr/share/applications/apifox.desktop
\`\`\`

Launch: \`/deployment/bin/apifox\`

启动参数：\`--no-sandbox --disable-gpu --disable-dev-shm-usage\`；
用户数据落在 \`${APIFOX_DATA}\`。
EOF

  # sam 在桌面会话里启动；数据目录必须可写
  chown -R sam:sam "${INSTALL_PATH}"
}

autoExecuteFunc setEnv installDeps installApifox initConfig
