#!/bin/bash
###
 # Install Claude Code (CLI) under /deployment/software/claude.
 # Layer layout (COPY-friendly):
 #   /deployment/software/claude/               # npm global prefix
 #   /deployment/bin/claude                     # launcher
 #
 # Upstream: @anthropic-ai/claude-code (npm)
 # 安装 Node.js 18+ + Claude Code CLI，amd64/arm64 统一。
###
source /deployment/scripts/common.sh

check_target_arch(){
  ARCH=$(uname -m)
  case $ARCH in
      x86_64|amd64)
          NODE_ARCH="x64"
          ;;
      aarch64|arm64)
          NODE_ARCH="arm64"
          ;;
      *)
          echo "未知架构: $ARCH"
          exit 1
          ;;
  esac
  export NODE_ARCH
  echo "目标架构: ${ARCH} (node=${NODE_ARCH})"
}

setEnv(){
  check_target_arch
  export DEBIAN_FRONTEND=noninteractive
  export INSTALL_PATH=/deployment/software/claude
  export NODE_VERSION=22

  # 默认跟随 latest；设置 CLAUDE_PIN_VERSION 可钉死版本
  CLAUDE_VERSION="${CLAUDE_PIN_VERSION:-latest}"
  export CLAUDE_VERSION

  echo "Using Claude Code ${CLAUDE_VERSION} (node ${NODE_VERSION})"
}

installDeps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl xz-utils
  apt-get clean -y
  rm -rf /var/lib/apt/lists/*

  # 安装 Node.js（官方二进制，统一 amd64/arm64）
  local node_url="https://nodejs.org/dist/v${NODE_VERSION}.0.0/node-v${NODE_VERSION}.0.0-linux-${NODE_ARCH}.tar.xz"
  local node_tmp="/tmp/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
  local node_extract="/tmp/node-extract"

  mkdir -p /usr/local/lib/nodejs
  rm -rf "${node_extract}" "${node_tmp}"

  echo "Downloading Node.js ${NODE_VERSION} from ${node_url}"
  curl -fsSL --connect-timeout 30 --max-time 300 -o "${node_tmp}" "${node_url}" || {
    echo "Failed to download Node.js" >&2
    return 1
  }

  mkdir -p "${node_extract}"
  tar -xJf "${node_tmp}" -C "${node_extract}"
  rm -f "${node_tmp}"

  local node_dir
  node_dir="$(find "${node_extract}" -maxdepth 1 -type d -name 'node-*' | head -n 1)"
  if [ -z "${node_dir}" ] || [ ! -d "${node_dir}" ]; then
    echo "Failed to extract Node.js" >&2
    return 1
  fi

  cp -a "${node_dir}/." /usr/local/lib/nodejs/
  rm -rf "${node_extract}"

  # 确保 node/npm/npx 全局可用
  ln -sfn /usr/local/lib/nodejs/bin/node   /usr/local/bin/node
  ln -sfn /usr/local/lib/nodejs/bin/npm    /usr/local/bin/npm
  ln -sfn /usr/local/lib/nodejs/bin/npx    /usr/local/bin/npx

  echo "Node.js $(node --version) installed"
}

installClaude(){
  mkdir -p /deployment/software /deployment/bin
  rm -rf "${INSTALL_PATH}"
  mkdir -p "${INSTALL_PATH}"

  local install_cmd="npm install -g --prefix ${INSTALL_PATH} @anthropic-ai/claude-code"

  if [ "${CLAUDE_VERSION}" != "latest" ]; then
    install_cmd="npm install -g --prefix ${INSTALL_PATH} @anthropic-ai/claude-code@${CLAUDE_VERSION}"
  fi

  echo "Installing: ${install_cmd}"
  ${install_cmd} || {
    echo "Failed to install Claude Code" >&2
    return 1
  }

  # 验证安装
  local claude_bin="${INSTALL_PATH}/bin/claude"
  if [ ! -x "${claude_bin}" ]; then
    echo "Claude Code binary missing: ${claude_bin}" >&2
    find "${INSTALL_PATH}" -maxdepth 4 -type f -perm -111 | head -n 20 >&2
    return 1
  fi

  export CLAUDE_BIN="${claude_bin}"
  CLAUDE_REAL_VERSION="$("${claude_bin}" --version 2>/dev/null | head -n 1 || echo "${CLAUDE_VERSION}")"
  export CLAUDE_REAL_VERSION
  echo "Claude Code version: ${CLAUDE_REAL_VERSION}"

  # ── 环境持久化 ─────────────────────────────────────────────
  write_cont_env CLAUDE_HOME "${INSTALL_PATH}"
  write_cont_env CLAUDE_BIN "${CLAUDE_BIN}"
  write_cont_env CLAUDE_VERSION "${CLAUDE_VERSION}"

  {
    echo "export CLAUDE_HOME=${INSTALL_PATH}"
    echo "export CLAUDE_BIN=${CLAUDE_BIN}"
    echo "export CLAUDE_VERSION=${CLAUDE_VERSION}"
    echo "export PATH=/deployment/bin:\$PATH"
  } >> /etc/environment
}

initConfig(){
  # ── launcher 符号链接 ────────────────────────────────────────
  ln -sfn "${INSTALL_PATH}/bin/claude" /deployment/bin/claude

  # ── README ──────────────────────────────────────────────────
  cat > "${INSTALL_PATH}/README.md" <<EOF
# Claude Code layer (COPY-friendly)

Installed from npm (\`@anthropic-ai/claude-code\`) under \`${INSTALL_PATH}\`.

\`\`\`dockerfile
COPY --from=<claude-image> /deployment/software/claude /deployment/software/claude
COPY --from=<claude-image> /deployment/bin/claude /deployment/bin/claude
\`\`\`

Launch: \`/deployment/bin/claude\`
Usage:  \`claude\` / \`claude -p "your prompt"\` / \`claude --interactive\`
EOF

  chown -R sarmn:sarmn "${INSTALL_PATH}"
}

autoExecuteFunc setEnv installDeps installClaude initConfig
