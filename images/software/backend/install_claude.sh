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

# Node.js 官方二进制的分发源，按顺序回退。已实测三处的 tar.xz 字节一致、
# SHA256 相同，所以换源不必重新解析版本号，校验和可以跨源复用：
#   nodejs.org              官方源，latest-v22.x 实时更新（版本最新）
#   cdn.npmmirror.com       国内镜像；latest-v22.x 可能滞后（只影响版本新旧）
#   mirrors.aliyun.com      国内镜像；只有 vX.Y.Z/ 目录，没有 latest-v22.x
NODE_DIST_SOURCES=(
  "https://nodejs.org/dist"
  "https://cdn.npmmirror.com/binaries/node"
  "https://mirrors.aliyun.com/nodejs-release"
)

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
  pkg_update || return 1
  pkg_install ca-certificates curl xz-utils || return 1
  pkg_clean

  local dest=/usr/local/lib/nodejs
  local node_file="" node_sha="" node_base=""

  # ── 1. 解析最新 v${NODE_VERSION}.x 的精确版本号与官方校验和 ────────────────
  # 只在 glibc 版的 .tar.xz 行上取值（行尾必须是 -linux-<arch>.tar.xz）：
  # SHASUMS256.txt 里 -musl 变体按文件名排在前面，早先用
  # `grep "linux-${NODE_ARCH}" | head -1` 取到的是 musl 包。
  local base shasums line
  for base in "${NODE_DIST_SOURCES[@]}"; do
    shasums="$(curl -fsSL --connect-timeout 20 --max-time 90 "${base}/latest-v${NODE_VERSION}.x/SHASUMS256.txt" 2>/dev/null)" || {
      echo "取 Node.js 版本清单失败，换下一个源: ${base}" >&2
      continue
    }
    line="$(printf '%s\n' "${shasums}" \
      | grep -E " node-v[0-9]+\.[0-9]+\.[0-9]+-linux-${NODE_ARCH}\.tar\.xz$" \
      | sort -V | tail -n 1)"
    [ -n "${line}" ] || { echo "清单里没有 linux-${NODE_ARCH} 的 .tar.xz: ${base}" >&2; continue; }
    node_sha="$(printf '%s\n' "${line}" | awk '{print $1}')"
    node_file="$(printf '%s\n' "${line}" | awk '{print $NF}')"
    node_base="${base}"
    echo "Node.js 版本清单来源: ${base} → ${node_file}"
    break
  done

  if [ -z "${node_file}" ]; then
    echo "Failed to determine latest Node.js v${NODE_VERSION} version" >&2
    return 1
  fi

  local node_ver="${node_file#node-v}"
  node_ver="${node_ver%-linux-*}"
  local node_tmp="/tmp/${node_file}"

  # 下载顺序：命中清单的源排最前，其余按原顺序兜底（去重，避免同一个源试两遍）
  local dl_sources=("${node_base}") s
  for s in "${NODE_DIST_SOURCES[@]}"; do
    [ "${s}" = "${node_base}" ] || dl_sources+=("${s}")
  done

  # 重试前先清干净：残留的半截 tar 包/半棵解出来的目录，只会让上一次的失败
  # 原样复现（也顺带修掉 dest 存在但是个普通文件的情况）
  rm -rf "${dest}" "${node_tmp}"
  mkdir -p "${dest}" || return 1

  # ── 2. 下载 + 校验（逐源回退，每源一次）──────────────────────────────────
  # 各源的 tar.xz 字节一致、校验和相同（已实测），所以校验和只用解析出清单的
  # 那个源的；换源只换下载地址，不重新解析版本号。
  # 每源只试一次、单次上限 300s：源连不通或中途卡死时能较快换到下一个，
  # 不至于在同一个源上反复等满超时。
  local got=""
  for base in "${dl_sources[@]}"; do
    echo "Downloading Node.js ${node_file} from ${base}"
    rm -f "${node_tmp}"
    if ! curl -fsSL --connect-timeout 30 --max-time 300 -o "${node_tmp}" \
           "${base}/v${node_ver}/${node_file}"; then
      echo "下载失败: ${base}/v${node_ver}/${node_file}" >&2
      continue
    fi
    # 校验和是发现"包不完整"的唯一关口：下载被截断、或中间缓存/代理回了个
    # 半截文件时 curl 仍可能返回 0，只靠 tar 报错会把原因指到解包上
    if printf '%s  %s\n' "${node_sha}" "${node_tmp}" | sha256sum -c - >/dev/null 2>&1; then
      got="yes"
      break
    fi
    echo "校验和不匹配（文件不完整或被改坏），换源重下: ${base}" >&2
  done

  if [ -z "${got}" ]; then
    echo "Failed to download Node.js (已尝试 ${#NODE_DIST_SOURCES[@]} 个源)" >&2
    ls -l "${node_tmp}" >&2 || true
    df -h "${dest}" >&2
    return 1
  fi

  # ── 3. 解包 ──────────────────────────────────────────────────────────────
  # 直接解到安装目录，--strip-components=1 去掉 node-vX.Y.Z-linux-<arch>/ 前缀。
  # 早先是"先解到 /tmp 再 cp -a 整棵复制"：多占一份 ~130MB 磁盘，且那一步没有
  # 错误检查——cp 失败（磁盘满、权限、目标非目录）时只会在最后报
  # "Node.js binary not found or not executable"，把真正的失败原因盖掉。
  if ! tar -xJf "${node_tmp}" -C "${dest}" --strip-components=1; then
    echo "Failed to extract Node.js tarball" >&2
    ls -l "${node_tmp}" >&2
    df -h "${dest}" >&2
    rm -f "${node_tmp}"
    return 1
  fi
  rm -f "${node_tmp}"
  chmod 0755 "${dest}/bin/node" 2>/dev/null || true

  # 确保 node/npm/npx 全局可用
  ln -sfn "${dest}/bin/node" /usr/local/bin/node
  ln -sfn "${dest}/bin/npm"  /usr/local/bin/npm
  ln -sfn "${dest}/bin/npx"  /usr/local/bin/npx

  # 验证 node 可执行
  if [ ! -x "${dest}/bin/node" ]; then
    echo "Node.js binary not found or not executable: ${dest}/bin/node" >&2
    ls -la "${dest}" "${dest}/bin" 2>&1 | head -40 >&2
    df -h "${dest}" >&2
    return 1
  fi

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
