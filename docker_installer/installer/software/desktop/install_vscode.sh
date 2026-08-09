#!/bin/bash
###
 # Install VS Code under /deployment/software/vscode.
 # Layer layout (COPY-friendly):
 #   /deployment/software/vscode/                # extracted .deb (usr/bin, usr/share, ...)
 #   /deployment/software/vscode/extensions/     # 预装插件
 #   /deployment/bin/vscode                      # launcher
 #
 # Upstream: https://code.visualstudio.com/download
 # 安装 VS Code 桌面版 + 常用插件，amd64/arm64 统一。
###
source /deployment/scripts/common.sh

check_target_arch(){
  ARCH=$(uname -m)
  case $ARCH in
      x86_64|amd64)
          TARGET_ARCH="x64"
          DEB_ARCH="amd64"
          ;;
      aarch64|arm64)
          TARGET_ARCH="arm64"
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
  export INSTALL_PATH=/deployment/software/vscode
  export VSCODE_EXTENSIONS="${INSTALL_PATH}/extensions"

  # 默认跟随 latest stable；设置 VSCODE_PIN_VERSION 可钉死版本
  VSCODE_VERSION="$(resolve_github_latest_tag microsoft/vscode VSCODE_PIN_VERSION)" || return 1
  export VSCODE_VERSION

  echo "Using VS Code ${VSCODE_VERSION} (${TARGET_ARCH})"
}

installDeps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates wget \
    libgtk-3-0 libx11-6 libxcb1 libxtst6 \
    libnss3 libnspr4 libgbm1 libasound2t64 \
    libatk-bridge2.0-0 libatspi2.0-0 \
    libcups2 libdrm2 libxcomposite1 libxdamage1 libxrandr2 \
    libxkbcommon0 libpango-1.0-0 libcairo2 \
    xdg-utils
  apt-get clean -y
  rm -rf /var/lib/apt/lists/*
}

installVscode(){
  local archive="code_${VSCODE_VERSION}-*_${DEB_ARCH}.deb"
  # VS Code 官方下载 URL（Microsoft 重定向）
  local url="https://update.code.visualstudio.com/${VSCODE_VERSION}/linux-deb-${TARGET_ARCH}/stable"
  local tmp="/tmp/vscode-${VSCODE_VERSION}_${DEB_ARCH}.deb"
  local extract_tmp="/tmp/vscode-extract"

  mkdir -p /deployment/software /deployment/bin
  rm -rf "${INSTALL_PATH}" "${extract_tmp}"
  mkdir -p "${extract_tmp}"

  echo "Downloading VS Code ${VSCODE_VERSION} from ${url}"
  wget -q --timeout=300 -O "${tmp}" "${url}" || {
    echo "Failed to download VS Code from ${url}" >&2
    return 1
  }

  # 解压 deb 到软件树，保持 COPY-friendly 布局
  dpkg-deb -x "${tmp}" "${extract_tmp}"
  rm -f "${tmp}"

  mkdir -p "${INSTALL_PATH}"
  if [ -d "${extract_tmp}/usr" ]; then
    mv "${extract_tmp}/usr" "${INSTALL_PATH}/usr"
  else
    echo "Unexpected deb layout:" >&2
    find "${extract_tmp}" -maxdepth 3 -print >&2
    return 1
  fi
  rm -rf "${extract_tmp}"

  # ── 定位可执行文件 ──────────────────────────────────────────
  local bin_path=""
  if [ -x "${INSTALL_PATH}/usr/bin/code" ]; then
    bin_path="${INSTALL_PATH}/usr/bin/code"
  elif [ -x "${INSTALL_PATH}/usr/share/code/bin/code" ]; then
    bin_path="${INSTALL_PATH}/usr/share/code/bin/code"
  else
    bin_path="$(find "${INSTALL_PATH}/usr" -type f -name 'code' -perm -111 2>/dev/null | head -n 1 || true)"
  fi
  if [ -z "${bin_path}" ] || [ ! -x "${bin_path}" ]; then
    echo "VS Code binary missing under ${INSTALL_PATH}" >&2
    find "${INSTALL_PATH}" -maxdepth 5 -type f | head -n 50 >&2
    return 1
  fi
  export VSCODE_BIN="${bin_path}"

  # ── 预装插件 ────────────────────────────────────────────────
  mkdir -p "${VSCODE_EXTENSIONS}"

  local extensions=(
    ms-python.python
    cweijan.vscode-mysql-client2
    github.github-vscode-theme
    charliermarsh.ruff
    natizyskunk.sftp
    ms-toolsai.jupyter
  )

  echo "Installing VS Code extensions..."
  for ext in "${extensions[@]}"; do
    echo "  ${ext}"
    "${VSCODE_BIN}" --extensions-dir "${VSCODE_EXTENSIONS}" --install-extension "${ext}" --no-sandbox 2>/dev/null || true
  done

  echo "VS Code version: ${VSCODE_VERSION}"

  # ── 环境持久化 ─────────────────────────────────────────────
  write_cont_env VSCODE_VERSION "${VSCODE_VERSION}"
  write_cont_env VSCODE_HOME "${INSTALL_PATH}"
  write_cont_env VSCODE_EXTENSIONS "${VSCODE_EXTENSIONS}"
  write_cont_env VSCODE_BIN "${VSCODE_BIN}"

  {
    echo "export VSCODE_HOME=${INSTALL_PATH}"
    echo "export VSCODE_EXTENSIONS=${VSCODE_EXTENSIONS}"
    echo "export VSCODE_BIN=${VSCODE_BIN}"
    echo "export VSCODE_VERSION=${VSCODE_VERSION}"
    echo "export PATH=/deployment/bin:\$PATH"
  } >> /etc/environment
}

initConfig(){
  # ── 启动包装脚本 ────────────────────────────────────────────
  cat > "${INSTALL_PATH}/vscode.sh" <<EOF
#!/bin/bash
export VSCODE_HOME="\${VSCODE_HOME:-${INSTALL_PATH}}"
export VSCODE_EXTENSIONS="\${VSCODE_EXTENSIONS:-${VSCODE_EXTENSIONS}}"
export VSCODE_BIN="\${VSCODE_BIN:-${VSCODE_BIN}}"

exec "\${VSCODE_BIN}" \\
  --no-sandbox \\
  --extensions-dir "\${VSCODE_EXTENSIONS}" \\
  "\$@"
EOF
  chmod +x "${INSTALL_PATH}/vscode.sh"
  ln -sfn "${INSTALL_PATH}/vscode.sh" /deployment/bin/vscode

  # ── 桌面菜单 ────────────────────────────────────────────────
  mkdir -p /usr/share/applications
  local icon=""
  icon="$(find "${INSTALL_PATH}/usr/share" -type f \( -name '*vscode*' -o -name '*code*' \) \( -name '*.png' -o -name '*.svg' \) 2>/dev/null | head -n 1 || true)"

  cat > /usr/share/applications/vscode.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=VS Code
Comment=Visual Studio Code
Exec=/deployment/bin/vscode
${icon:+Icon=${icon}}
Terminal=false
Categories=Development;IDE;
EOF

  # ── README ──────────────────────────────────────────────────
  cat > "${INSTALL_PATH}/README.md" <<EOF
# VS Code layer (COPY-friendly)

Installed from Microsoft official repo under \`${INSTALL_PATH}\`.
Pre-installed extensions: \`${VSCODE_EXTENSIONS}\`.

\`\`\`dockerfile
COPY --from=<vscode-image> /deployment/software/vscode /deployment/software/vscode
COPY --from=<vscode-image> /deployment/bin/vscode /deployment/bin/vscode
\`\`\`

Launch: \`/deployment/bin/vscode\`
EOF

  chown -R sarmn:sarmn "${INSTALL_PATH}"
}

autoExecuteFunc setEnv installDeps installVscode initConfig
