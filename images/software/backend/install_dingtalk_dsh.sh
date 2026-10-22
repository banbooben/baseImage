#!/bin/bash
###
 # Install 钉钉数字同事（DingTalk digital colleague）—— backend 软件。
 #
 # 组件（对应需求）：
 #   DSH  @deepseek-ai/dsh            DeepSeek Harness Agent 运行时（Node >= 24）
 #   DWS  dingtalk-workspace-cli      钉钉工作台 CLI：登录态 + 群消息通道
 #   插件  dingtalk-dsh-assistant     把钉钉群聊接入 DSH 常驻会话
 #
 # 安装顺序：
 #   1. Node.js 24（DSH 要求 ^22.19.0 || >=24；dingtalk-dsh-assistant 要求 Node 24+；
 #      仓库 base:<os> 不带 Node，这里照 install_claude.sh 的套路自举官方二进制）
 #   2. DWS：官方 install.sh 装 standalone 二进制（不走 npm——npm 安装的 dws upgrade
 #      会委派包管理器写 /usr/local，sarmn 不可写且随容器重建丢失；standalone 的
 #      upgrade 原地原子替换自身二进制，配合 ~/.local/bin 挂卷，容器内升级持久）
 #   3. DSH：npm i -g @deepseek-ai/dsh（钉版本，默认 0.2.1-alpha.2）
 #   4. 插件：dsh plugin --profile web add dingtalk-dsh-assistant@<钉版本>（bake 进种子目录；
 #      配对规则：assistant 2.x 把 @deepseek-ai/* 依赖精确钉在 0.2.1-alpha.2，DSH 运行时
 #      必须钉同一版本——钉高了（如 0.2.1-rc.2）dedup 全部 SKIP、dsh 兼容性检查直接把
 #      profile 插件 disable，机器人不可用）
 #   5. 去重：dedup @deepseek-ai 双副本（dsh 运行时与 profile 插件各装了一份同名同版本
 #      的 @deepseek-ai 包，dsh-tools 的调度器 Symbol 跨副本失配导致工具调用必崩、
 #      机器人永远无回复；symlink 单副本修复，见 docs/dsh-dws修复方案/DEDUP-FIX.md）
 #
 # Layer layout（方案 C：不设 DSH_HOME/DWS_CONFIG_DIR，一切走运行用户 home 默认路径；
 # 需要持久化的目录由 compose 按路径单独挂卷；bake 进这些路径的内容统一先落到
 # SEED_HOME，运行期 start 脚本在卷内缺失时拷入，已有内容一律不覆盖）：
 #   /deployment/accounts/sarmn/.dsh                 # DSH 数据域：会话/轨迹/插件（种子含 assistant）
 #   /deployment/accounts/sarmn/.dws                 # DWS profiles/技能状态/技能（种子含技能）
 #   /deployment/accounts/sarmn/.agents/skills       # 技能（multi 模式，种子含）
 #   /deployment/accounts/sarmn/.local/share/dws-cli # DWS 凭证库（dek + auth-token*.enc）
 #   /deployment/accounts/sarmn/.local/bin/dws       # DWS standalone 二进制（种子含；upgrade 原地替换）
 #   /deployment/software/dingtalk-dsh/seed-home     # SEED_HOME：上述初始内容的种子（镜像内，不挂卷）
 #   /deployment/bin/dingtalk-dsh-start.sh           # s6 longrun 的 run body
 #   /deployment/bin/dsh / dws                        # 启动器（dsh→npm 全局 bin；dws→卷内 standalone）
 #
 # 构建期可覆盖（Dockerfile build-arg / 环境变量）：
 #   NPM_REGISTRY     npm 源（默认 https://registry.npmmirror.com）
 #   DWS_PIN_VERSION  DWS 版本（默认 latest；可写 1.0.65 或 v1.0.65）
 #   DSH_PIN_VERSION  DSH 版本（默认 0.2.1-alpha.2；须与插件钉的 @deepseek-ai/* 版本一致）
 #   DSH_ASSISTANT_PIN_VERSION  钉钉插件版本（默认 2.1.0；2.x 插件依赖 dsh 0.2.x
 #                              API 代际，其 @deepseek-ai/* 依赖精确钉 0.2.1-alpha.2，必须配对钉住）
 #
 # 上游：
 #   DWS  https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli
 #   插件  https://www.npmjs.com/package/dingtalk-dsh-assistant
 #   DSH  @deepseek-ai/dsh（DeepSeek Harness 官方文档）
###
source /deployment/scripts/common.sh

# Node.js 官方二进制的分发源，按顺序回退。已实测三处的 tar.xz 字节一致、
# SHA256 相同，所以换源不必重新解析版本号，校验和可以跨源复用：
#   nodejs.org              官方源，latest-v24.x 实时更新（版本最新）
#   cdn.npmmirror.com       国内镜像；latest-v24.x 可能滞后（只影响版本新旧）
#   mirrors.aliyun.com      国内镜像；只有 vX.Y.Z/ 目录，没有 latest-v24.x
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
  export INSTALL_PATH=/deployment/software/dingtalk-dsh
  export NODE_VERSION=24

  export NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
  # npm/pnpm 子进程统一走这个源（dsh plugin add 内部会调 pnpm/npm）
  export NPM_CONFIG_REGISTRY="${NPM_REGISTRY}"
  export DWS_PIN_VERSION="${DWS_PIN_VERSION:-}"
  export DSH_PIN_VERSION="${DSH_PIN_VERSION:-0.2.1-alpha.2}"
  export DSH_ASSISTANT_PIN_VERSION="${DSH_ASSISTANT_PIN_VERSION:-2.1.0}"

  # 种子目录：bake 期所有要进挂卷的初始内容（dsh profile、dws 二进制、技能）
  # 都以 HOME=SEED_HOME 落到这里；运行期 start 脚本把卷内缺失的部分拷入。
  export SEED_HOME="${INSTALL_PATH}/seed-home"

  echo "Using DSH ${DSH_PIN_VERSION} (node ${NODE_VERSION}, registry ${NPM_REGISTRY})"
}

installDeps(){
  export DEBIAN_FRONTEND=noninteractive
  pkg_update || return 1
  pkg_install ca-certificates curl xz-utils git procps || return 1
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
  local got=""
  for base in "${dl_sources[@]}"; do
    echo "Downloading Node.js ${node_file} from ${base}"
    rm -f "${node_tmp}"
    if ! curl -fsSL --connect-timeout 30 --max-time 300 -o "${node_tmp}" \
           "${base}/v${node_ver}/${node_file}"; then
      echo "下载失败: ${base}/v${node_ver}/${node_file}" >&2
      continue
    fi
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

  if [ ! -x "${dest}/bin/node" ]; then
    echo "Node.js binary not found or not executable: ${dest}/bin/node" >&2
    ls -la "${dest}" "${dest}/bin" 2>&1 | head -40 >&2
    df -h "${dest}" >&2
    return 1
  fi

  echo "Node.js $(node --version) installed"

  # npm 全局 prefix：官方 tarball 解到 /usr/local/lib/nodejs 后，npm 会把默认 prefix
  # 推导成 /usr/local/lib/nodejs，导致 `npm i -g` 的 bin（dsh/pnpm）落到
  # /usr/local/lib/nodejs/bin —— 该目录不在构建期 PATH 上，装完 `dsh` 会 command not found。
  # 显式钉回 /usr/local，让 global bin 进 /usr/local/bin（与上面 node/npm/npx 软链一致）。
  npm config set prefix /usr/local || return 1

  # npm 源 + pnpm（dsh plugin add 内部依赖 pnpm 解析/安装插件包）。
  # 钉 pnpm@10：pnpm 11+ 把「未批准的依赖构建脚本」从警告升级为硬错误
  # （ERR_PNPM_IGNORED_BUILDS），而白名单配置（allowBuilds / dangerouslyAllowAllBuilds）
  # 只能写进项目根的 pnpm-workspace.yaml —— 插件安装在 dsh 自己生成的 profile 目录里
  # 进行，外部没有稳定的配置注入点。插件依赖 koffi 的 install 脚本只是选装其自带的
  # 预编译二进制，pnpm 10 下忽略（仅警告）即可，与此前成功构建的行为一致。
  npm config set registry "${NPM_REGISTRY}" || return 1
  npm install -g pnpm@10 --registry="${NPM_REGISTRY}" || return 1
  pnpm config set registry "${NPM_REGISTRY}" 2>/dev/null || true
  echo "pnpm $(pnpm --version 2>/dev/null || echo latest) installed"
}

installDws(){
  mkdir -p /deployment/bin "${SEED_HOME}/.local/bin"

  # DWS 走官方 install.sh 装 standalone 二进制（不是 npm 包）。脚本自带：
  # 架构识别（amd64/arm64）、checksums.txt SHA256 校验（校验不过拒绝安装）、
  # GitHub 不可达时自动回退 Gitee 镜像、技能安装（multi 模式：~/.agents/skills +
  # ~/.dws/skills）与技能状态落 $HOME/.dws。
  # bake 时 HOME 指到 SEED_HOME，二进制与技能全部落进种子目录。
  local version="${DWS_PIN_VERSION}"
  if [ -n "${version}" ]; then
    version="v${version#v}"
  else
    # 解析 latest tag；GitHub API 不可达时留空，交给官方脚本自己解析（含 Gitee 回退）
    version="$(curl -fsSL --connect-timeout 15 --max-time 45 \
      https://api.github.com/repos/DingTalk-Real-AI/dingtalk-workspace-cli/releases/latest 2>/dev/null \
      | grep -o '"tag_name"[^,}]*' | cut -d'"' -f4 || true)"
  fi
  echo "DWS version: ${version:-latest (resolved by install.sh)}"

  # 安装脚本按 tag 拉取（与二进制同版本，保证可复现）；tag 上没有时回退 main
  local script=/tmp/dws-install.sh
  rm -f "${script}"
  if [ -n "${version}" ]; then
    curl -fsSL --connect-timeout 20 --max-time 90 -o "${script}" \
      "https://raw.githubusercontent.com/DingTalk-Real-AI/dingtalk-workspace-cli/${version}/scripts/install.sh" || true
  fi
  if [ ! -s "${script}" ]; then
    curl -fsSL --connect-timeout 20 --max-time 90 -o "${script}" \
      "https://raw.githubusercontent.com/DingTalk-Real-AI/dingtalk-workspace-cli/main/scripts/install.sh" || {
      echo "Failed to download DWS install.sh" >&2; return 1; }
  fi

  local install_env=(HOME="${SEED_HOME}" DWS_INSTALL_DIR="${SEED_HOME}/.local/bin" DWS_SKILL_MODE=multi)
  [ -n "${version}" ] && install_env+=(DWS_VERSION="${version}")
  env "${install_env[@]}" sh "${script}" || { echo "Failed to install DWS (standalone)" >&2; return 1; }

  "${SEED_HOME}/.local/bin/dws" version || { echo "DWS binary missing or broken" >&2; return 1; }
  DWS_VERSION="$("${SEED_HOME}/.local/bin/dws" version 2>/dev/null | head -n 1 || echo "${version:-latest}")"
  export DWS_VERSION
  echo "DWS ${DWS_VERSION} installed (standalone, seeded at ${SEED_HOME}/.local/bin/dws)"
}

installDsh(){
  local install_cmd="npm install -g @deepseek-ai/dsh@${DSH_PIN_VERSION} --allow-scripts=@deepseek-ai/dsh --registry=${NPM_REGISTRY}"

  echo "Installing: ${install_cmd}"
  ${install_cmd} || { echo "Failed to install DSH (@deepseek-ai/dsh@${DSH_PIN_VERSION})" >&2; return 1; }

  # 验证安装
  dsh --version || dsh version || { echo "DSH binary missing or broken" >&2; return 1; }

  local dsh_bin
  dsh_bin="$(command -v dsh)"
  ln -sfn "${dsh_bin}" /deployment/bin/dsh
  DSH_VERSION="$(dsh --version 2>/dev/null | head -n 1 || echo "${DSH_PIN_VERSION}")"
  export DSH_VERSION
  echo "DSH version: ${DSH_VERSION}"
}

# 装配 assistant resident Runtime 的幂等脚本（bake 时与运行期 start 脚本都会调）。
# 背景：插件的 Web 设置页通过硬编码 http://127.0.0.1:18998 拉取 dws 状态；
# `dsh plugin add` 只装 web face（2.x 的 bundle patch 只插 web + observer，两者
# 都是客户端层），真正的 resident 后端（@zzusp/dingtalk-dsh-assistant 的
# ./resident 导出，监听 18998）必须显式插进实际使用的 Web profile patch——不插则
# 18998 无人监听，设置页 fetch 失败，永远显示「dws 未安装」（与配置目录、运行
# 用户均无关）。2.1.0 起 resident 的 inject 全部是 dsh 核心服务，不再需要
# 1.0.0 时代的 dingtalkTaskWorkflowPlatformClients 占位 stub。
writeAssembleResidentScript(){
  mkdir -p /deployment/bin
  cat > /deployment/bin/dingtalk-dsh-assemble-resident.sh <<'EOF'
#!/bin/bash
# 装配 assistant resident Runtime（dingtalk-dsh-assistant README §3），幂等：
# 整块用标记注释管理，每次调用重写；dws.profile 从 DWS_CONFIG_DIR/profiles.json
# 的 currentProfile 派生（仅用于设置页 auth status 展示，取不到则省略该行）。
# 方案 C：不设环境变量时按默认路径解析（$HOME/.dsh、$HOME/.dws），调用方必须
# 保证 HOME 指向目标用户的 home（bake 时是 SEED_HOME，运行期 start 脚本是 sarmn home）。
set -e

DSH_HOME="${DSH_HOME:-${HOME}/.dsh}"
DWS_CONFIG_DIR="${DWS_CONFIG_DIR:-${HOME}/.dws}"

PROFILE_DIR="${DSH_HOME}/profiles/web"
PATCH_FILE="${PROFILE_DIR}/cordis.patch.yml"

# profile 尚未生成（全新 home 还没 dsh plugin add）时跳过
[ -f "${PATCH_FILE}" ] || exit 0

# 清掉旧的受管块（幂等）
sed -i '/# >>> dingtalk-dsh-assistant resident/,/# <<< dingtalk-dsh-assistant resident/d' "${PATCH_FILE}"

# 剩余内容只有模板注释 + 空数组时，把空数组行删掉（否则 append 的列表项
# 接在 [] 后面不是合法 YAML）
if [ -z "$(grep -vE '^\s*(#|$)' "${PATCH_FILE}" | grep -v '^\[\]$')" ]; then
  sed -i '/^\[\]$/d' "${PATCH_FILE}"
fi

DWS_PROFILE="$(grep -o '"currentProfile"[^,}]*' "${DWS_CONFIG_DIR}/profiles.json" 2>/dev/null | cut -d'"' -f4 || true)"

# taskSessions（assistant 2.x 必填，缺了 resident 激活失败：
# TASK_SESSION_CONFIGURATION_REQUIRED:<field>）。语义见 wrapper README
# 「持久账、通知与恢复」：instanceId / ingressEpoch 须稳定——首次装配时生成并
# 持久化在 TASK_STATE_DIR，之后重启复用；ingressEpoch 是消息摄入时间下界，
# 首次取值即装配时刻（bake 时 = 构建时刻，随后 seed 带进卷）。initialize 等价
# 实现 README 的「确认初始化成功后改回 false」：DB 不存在才 true。
TASK_STATE_DIR="${DSH_HOME}/storages/dingtalk-dsh-assistant"
TASK_DB="${TASK_STATE_DIR}/task-sessions.db"
mkdir -p "${TASK_STATE_DIR}"
[ -s "${TASK_STATE_DIR}/instance-id" ] || cat /proc/sys/kernel/random/uuid > "${TASK_STATE_DIR}/instance-id"
[ -s "${TASK_STATE_DIR}/ingress-epoch" ] || date -u +%Y-%m-%dT%H:%M:%SZ > "${TASK_STATE_DIR}/ingress-epoch"
TASK_INSTANCE_ID="$(cat "${TASK_STATE_DIR}/instance-id")"
TASK_INGRESS_EPOCH="$(cat "${TASK_STATE_DIR}/ingress-epoch")"
[ -f "${TASK_DB}" ] && TASK_INIT=false || TASK_INIT=true
# ownerActorId：钉钉侧 senderOpenDingTalkId，静态特权身份（可取消任意任务、
# requester 回路由它匹配）；webActorId：Web 控制台消息挂的身份。两者都只需
# 稳定非空字符串。owner 与 instanceId 同样须稳定——优先级：-e 覆盖 > 持久化 >
# 默认 owner；解析结果写回状态目录，容器重建丢环境变量后仍保持原身份。
[ -s "${TASK_STATE_DIR}/owner-actor-id" ] || echo "${DINGTALK_OWNER_ACTOR_ID:-owner}" > "${TASK_STATE_DIR}/owner-actor-id"
TASK_OWNER="${DINGTALK_OWNER_ACTOR_ID:-$(cat "${TASK_STATE_DIR}/owner-actor-id")}"
TASK_WEB_ACTOR="${DINGTALK_WEB_ACTOR_ID:-web-console}"
# agentWorkspaceDir：任务工作区根（每个任务的 materials/work/tmp/outputs 父级）。
# 不配置时 resident 回退 process.cwd()——s6 longrun 的 cwd 是只读 servicedir，
# task-session-persistence 建 tasks/ 直接 EACCES 导致 resident 激活失败。放 .dsh 卷内持久。
AGENT_WORKSPACE="${DSH_HOME}/workspace"
mkdir -p "${AGENT_WORKSPACE}"

{
  echo "# >>> dingtalk-dsh-assistant resident (managed, do not edit between markers) >>>"
  echo "- insert:"
  echo "    - id: dingtalk-dsh-assistant-resident"
  echo "      name: \"@zzusp/dingtalk-dsh-assistant/resident\""
  echo "      config:"
  echo "        groups: []"
  echo "        agentWorkspaceDir: ${AGENT_WORKSPACE}"
  echo "        dws:"
  # 默认启用：群消息接收（enabled，inbound bridge）+ 自动回复（writesAuthorized，
  # outbound）。quoted heredoc 不展开——assemble 在容器启动时执行，可用
  # docker run -e DWS_BRIDGE_ENABLED=false / DWS_WRITES_AUTHORIZED=false 按部署关闭。
  echo "          enabled: ${DWS_BRIDGE_ENABLED:-true}"
  echo "          writesAuthorized: ${DWS_WRITES_AUTHORIZED:-true}"
  [ -n "${DWS_PROFILE}" ] && echo "          profile: ${DWS_PROFILE}"
  echo "        taskSessions:"
  echo "          dbPath: ${TASK_DB}"
  echo "          instanceId: ${TASK_INSTANCE_ID}"
  echo "          ownerActorId: ${TASK_OWNER}"
  echo "          webActorId: ${TASK_WEB_ACTOR}"
  echo "          ingressEpoch: ${TASK_INGRESS_EPOCH}"
  echo "          initialize: ${TASK_INIT}"
  echo "# <<< dingtalk-dsh-assistant resident <<<"
} >> "${PATCH_FILE}"
EOF
  chmod 0755 /deployment/bin/dingtalk-dsh-assemble-resident.sh
}

# 消除 @deepseek-ai 双副本的幂等脚本（bake 时与运行期 start 脚本都会调）。
# 根因（docs/dsh-dws修复方案/DEDUP-FIX.md）：dsh 运行时（本镜像是全局 npm 树）与
# profile 插件（profiles/web/node_modules）各自装了一份同名同版本的 @deepseek-ai/*
# 包。其中 dsh-tools 内部 `Symbol("@deepseek-ai/dsh-tools.scheduler")` 每次 require
# 都是新实例，两份副本各得一个不相等的 Symbol；协调器子 agent 用 A 副本的 Symbol
# 去查 B 副本注册的调度器 → undefined → `.prepare()` 崩溃：
#   Cannot read properties of undefined (reading 'prepare')
# 群里表现为：消息收得到、模型能理解、也调了工具，但工具一执行就崩，机器人永远无回复。
# 修复：profile 侧的重叠包 symlink 复用运行时那份（版本一致才 link，保证模块实例唯一）。
writeDedupScript(){
  mkdir -p /deployment/bin
  cat > /deployment/bin/dedup-dsh-packages.sh <<'EOF'
#!/bin/bash
# 消除 dsh 运行时与 profile 插件（profiles/web/node_modules）之间的
# @deepseek-ai/* 双副本问题（docs/dsh-dws修复方案/DEDUP-FIX.md）。
#
# 注意：profile 侧任何一次 pnpm/npm install（nodeLinker=hoisted）都会重新
# hoist 真目录、覆盖 symlink，所以 bake（plugin add 之后）与运行期（start
# 脚本）都要执行本脚本；幂等，已正确的 symlink 直接跳过。
#
# 用法：dedup-dsh-packages.sh [--dsh-tools-only]   # 默认去重全部重叠包
# 环境变量覆盖：
#   DSH_RUNTIME_NM   dsh 运行时 node_modules 根目录（默认从 dsh bin 真实路径反推）
#   DSH_PROFILE_NM   profile web 的 node_modules 根目录（默认 $HOME/.dsh/profiles/web/node_modules）
set -euo pipefail

SCOPE="${1:---all}"
RUNTIME_NM="${DSH_RUNTIME_NM:-}"
PROFILE_NM="${DSH_PROFILE_NM:-$HOME/.dsh/profiles/web/node_modules}"

# 本镜像 dsh 是全局 npm 安装：/usr/local/bin/dsh → <prefix>/lib/node_modules/
# @deepseek-ai/dsh/lib/bin.js。其依赖（dsh-tools 等）随 npm hoist 策略落在
# 全局 node_modules 根或 dsh 包内 node_modules，两处都探测。
discover_runtime() {
  local dsh_bin root cand
  dsh_bin="$(readlink -f "$(command -v dsh)" 2>/dev/null)" || return 1
  case "${dsh_bin}" in
    */node_modules/@deepseek-ai/dsh/lib/bin.js) ;;
    *) return 1 ;;
  esac
  root="${dsh_bin%/node_modules/@deepseek-ai/dsh/lib/bin.js}/node_modules"
  for cand in "${root}/@deepseek-ai/dsh/node_modules" "${root}"; do
    if [ -d "${cand}/@deepseek-ai/dsh-tools" ]; then
      RUNTIME_NM="${cand}"
      return 0
    fi
  done
  return 1
}

if [ -z "${RUNTIME_NM}" ]; then
  if ! discover_runtime; then
    echo "ERROR: 无法定位 dsh 运行时 node_modules（可设 DSH_RUNTIME_NM 显式指定）" >&2
    exit 1
  fi
fi

RUNTIME_DS="${RUNTIME_NM}/@deepseek-ai"
PROFILE_DS="${PROFILE_NM}/@deepseek-ai"
[ -d "${RUNTIME_DS}" ] || { echo "ERROR: 运行时 @deepseek-ai 目录不存在: ${RUNTIME_DS}" >&2; exit 1; }
[ -d "${PROFILE_DS}" ] || { echo "ERROR: profile @deepseek-ai 目录不存在: ${PROFILE_DS}" >&2; exit 1; }

ver() { node -p "JSON.parse(require('fs').readFileSync('$1/package.json','utf8')).version" 2>/dev/null || echo ''; }

linked=0; skipped=0; mismatched=0
for pkgdir in "${PROFILE_DS}"/*/; do
  name="$(basename "${pkgdir}")"
  case "${name}" in *.orig.bak|*.orig.bak.*) continue;; esac  # 跳过历史备份
  [ -d "${RUNTIME_DS}/${name}" ] || continue                    # 只处理两边都存在的重叠包
  [ "${SCOPE}" = "--dsh-tools-only" ] && [ "${name}" != "dsh-tools" ] && continue

  wv="$(ver "${PROFILE_DS}/${name}")"; nv="$(ver "${RUNTIME_DS}/${name}")"
  if [ "${wv}" != "${nv}" ]; then
    echo "SKIP  ${name}  版本不一致 profile=${wv} runtime=${nv}"
    mismatched=$((mismatched+1)); continue
  fi

  target="${PROFILE_DS}/${name}"
  if [ -L "${target}" ] && [ "$(readlink -f "${target}")" = "$(readlink -f "${RUNTIME_DS}/${name}")" ]; then
    echo "OK    ${name}  (已是单副本 symlink)"
    skipped=$((skipped+1)); continue
  fi
  [ -L "${target}" ] && rm "${target}"
  [ -e "${target}" ] && mv "${target}" "${target}.orig.bak.$(date +%s)"
  ln -s "${RUNTIME_DS}/${name}" "${target}"
  echo "LINK  ${name}  ->  ${RUNTIME_DS}/${name}"
  linked=$((linked+1))
done

echo "dedup-dsh-packages: symlink ${linked}, 已正确 ${skipped}, 版本不一致跳过 ${mismatched}"
EOF
  chmod 0755 /deployment/bin/dedup-dsh-packages.sh
}

installAssistant(){
  mkdir -p "${SEED_HOME}"
  writeAssembleResidentScript
  writeDedupScript

  # 把钉钉群接入插件装进种子 home 的默认 DSH 数据域（${SEED_HOME}/.dsh，web profile；
  # 运行期 start 脚本在卷内缺失时拷入）。版本必须配对钉：assistant 2.x 依赖 dsh
  # 0.2.x API 代际，与 dsh 0.1.x 不兼容。dsh 的数据域解析：不设 DSH_HOME 时回退
  # $HOME/.dsh，故以 HOME=SEED_HOME 调用（bake 期 HOME 是 /root，绝不能落进 /root）。
  echo "Installing dingtalk-dsh-assistant@${DSH_ASSISTANT_PIN_VERSION} into ${SEED_HOME}/.dsh (profile=web)"
  HOME="${SEED_HOME}" dsh plugin --profile web add "dingtalk-dsh-assistant@${DSH_ASSISTANT_PIN_VERSION}" || {
    echo "Failed to install dingtalk-dsh-assistant plugin" >&2
    return 1
  }
  # 装配 resident Runtime 进 web profile patch（设置页「dws 未安装」的根源修复；
  # 详见 writeAssembleResidentScript 注释）
  HOME="${SEED_HOME}" /deployment/bin/dingtalk-dsh-assemble-resident.sh || {
    echo "Failed to assemble assistant resident runtime" >&2
    return 1
  }
  # 消除 @deepseek-ai 双副本：必须在 plugin add（内部 pnpm install，nodeLinker=hoisted
  # 会重新 hoist 真目录）之后执行，symlink 才不被覆盖。不修则 dsh-tools 调度器
  # Symbol 跨副本失配，工具调用必崩、群消息永远无回复（详见 writeDedupScript 注释）。
  # bake 失败要直接让构建失败——dedup 跑不起来说明插件布局变了，带出去就是废镜像。
  HOME="${SEED_HOME}" /deployment/bin/dedup-dsh-packages.sh || {
    echo "Failed to dedup @deepseek-ai packages" >&2
    return 1
  }
  # 种子不保留 .orig.bak 备份（会被 start 脚本 cp -a 带进卷，白白占空间）
  rm -rf "${SEED_HOME}"/.dsh/profiles/web/node_modules/@deepseek-ai/*.orig.bak.* 2>/dev/null || true
  echo "dingtalk-dsh-assistant installed into ${SEED_HOME}/.dsh"
}

initS6Config(){
  mkdir -p "${INSTALL_PATH}"

  # 种子整目录收归 sarmn：start 脚本 cp -a 进卷时保留属主，卷内容直接归运行用户
  # （PUID/PGID 改 uid/gid 的场景由 start 脚本的 chown -R 兜底）
  chown -R sarmn:sarmn "${INSTALL_PATH}" 2>/dev/null || true

  # ── s6 longrun 的 run body ────────────────────────────────────────────
  # run body 以 root 启动（register_s6_longrun_cmd 不传 run_user），先在 root 态完成
  # 种子拷贝 + 属主修正，再 setuidgid 切到 sarmn 前台常驻 DSH Web；重启语义交给 s6。
  # PUID/PGID 的 uid/gid 对齐由 base 层 /etc/cont-init.d/05-puid-pgid 在服务启动前
  # 统一完成，此处不再重复。持久化不设 DSH_HOME/DWS_CONFIG_DIR——DSH/DWS 的默认
  # 路径全在运行用户 home（$HOME/.dsh、$HOME/.dws、~/.agents、~/.local/...），
  # 由 compose 按目录单独挂卷。
  cat > /deployment/bin/dingtalk-dsh-start.sh <<EOF
#!/bin/bash
set -e

RUN_USER="sarmn"
HOME_DIR="\$(getent passwd "\${RUN_USER}" | cut -d: -f6)"
[ -n "\${HOME_DIR}" ] || HOME_DIR="/deployment/accounts/\${RUN_USER}"
SEED_HOME="${INSTALL_PATH}/seed-home"

# 持久化点（compose 按目录单独挂卷；未挂的目录随容器重建丢失，只剩凭证库必须挂）
mkdir -p "\${HOME_DIR}/.dsh" "\${HOME_DIR}/.dws" "\${HOME_DIR}/.agents" \\
         "\${HOME_DIR}/.local/share/dws-cli" "\${HOME_DIR}/.local/bin"

# 凭证库目录收紧（dek + auth-token*.enc）
chmod 700 "\${HOME_DIR}/.local/share/dws-cli" 2>/dev/null || true

# 种子拷贝：镜像 bake 的初始状态只在目标缺失时拷入——卷里已有的内容
# （升级过的 dws 二进制、用户改过的 profile/技能）一律不被种子覆盖。
if [ ! -e "\${HOME_DIR}/.dsh/profiles/web/package.json" ] && [ -d "\${SEED_HOME}/.dsh" ]; then
  cp -a "\${SEED_HOME}/.dsh/." "\${HOME_DIR}/.dsh/"
fi
if [ ! -e "\${HOME_DIR}/.dws/skills" ] && [ -d "\${SEED_HOME}/.dws" ]; then
  cp -a "\${SEED_HOME}/.dws/." "\${HOME_DIR}/.dws/"
fi
if [ ! -e "\${HOME_DIR}/.agents/skills" ] && [ -d "\${SEED_HOME}/.agents" ]; then
  cp -a "\${SEED_HOME}/.agents/." "\${HOME_DIR}/.agents/"
fi
if [ ! -x "\${HOME_DIR}/.local/bin/dws" ] && [ -f "\${SEED_HOME}/.local/bin/dws" ]; then
  cp -a "\${SEED_HOME}/.local/bin/dws" "\${HOME_DIR}/.local/bin/dws"
fi

# dws 上 PATH（/deployment/bin 在镜像 ENV PATH 最前）。standalone 的 dws upgrade
# 解析可执行文件真实路径后原地原子替换，替换对象是卷内二进制 → 升级持久。
ln -sfn "\${HOME_DIR}/.local/bin/dws" /deployment/bin/dws

# 消除 @deepseek-ai 双副本（幂等兜底）：seed 拷入的 symlink 已正确时秒过；运行期
# 手工 dsh plugin add / 重装插件会重新 hoist 真目录覆盖 symlink，这里在每次启动前
# 补一遍。失败不阻断启动（dedup 内部对版本不一致的包只会跳过、不会误伤）。
if [ -d "\${HOME_DIR}/.dsh/profiles/web/node_modules/@deepseek-ai" ]; then
  HOME="\${HOME_DIR}" /deployment/bin/dedup-dsh-packages.sh || true
fi

# 重 chown 家目录：PUID/PGID 改过 sarmn 的 uid/gid 后，bake/旧卷里的旧属主文件
# 新 sarmn 读写不了（种子刚拷出来的文件也一并归位）
chown -R "\${RUN_USER}:\${RUN_USER}" "\${HOME_DIR}" 2>/dev/null || true

# DWS 登录态自检：凭证库（dek + auth-token*.enc）为空 = 尚未登录，只提醒，不阻断
# DSH 起服务。方案 C 无 DWS_CONFIG_DIR，登录态/配置都走默认路径，登录直接：
#   docker exec -it -u sarmn <container> dws auth login --device
if ! ls "\${HOME_DIR}/.local/share/dws-cli"/auth-token*.enc >/dev/null 2>&1; then
  echo "[dingtalk-dsh] 未检测到 DWS 登录态（dws-cli 凭证库为空）；请先执行: docker exec -it -u \${RUN_USER} <container> dws auth login --device" >&2
fi

# 装配 assistant resident Runtime（幂等；手工重 add 插件后这里补齐 patch，并从
# profiles.json 刷新 dws.profile）。设置页「dws 未安装」的根源修复：web face 是
# no-op，状态来自 resident 的 127.0.0.1:18998 服务。此进程还是 root，assemble
# 按 \$HOME 解析默认路径，必须显式给 HOME。
HOME="\${HOME_DIR}" /deployment/bin/dingtalk-dsh-assemble-resident.sh || true
# assemble 以 root 执行：patch（profiles 下）与 taskSessions 状态目录都要归还给
# 运行用户，否则 sarmn 身份的 dsh 写不动 task-sessions.db
chown -R "\${RUN_USER}:\${RUN_USER}" "\${HOME_DIR}/.dsh" 2>/dev/null || true

# s6-setuidgid 不改 HOME（仍是 root 的）；dws 凭证走 XDG（\$HOME/.local/share/dws-cli），
# 不把 HOME 归位到运行用户，服务及插件子进程永远读不到登录态
exec s6-setuidgid "\${RUN_USER}" env HOME="\${HOME_DIR}" dsh web --no-open
EOF
  chmod 0755 /deployment/bin/dingtalk-dsh-start.sh

  # ── 运行期环境持久化（s6 with-contenv 会注入）────────────────────────
  write_cont_env DSH_PIN_VERSION "${DSH_PIN_VERSION}"
  write_cont_env DSH_VERSION "${DSH_VERSION}"
  write_cont_env DWS_VERSION "${DWS_VERSION}"

  echo "export PATH=/deployment/bin:\$PATH" >> /etc/environment

  # 注册常驻服务：run body 以 root 起，属主修正后 setuidgid 切到 sarmn 常驻
  register_s6_longrun_cmd dingtalk-dsh "exec /bin/bash /deployment/bin/dingtalk-dsh-start.sh"

  # ── README ────────────────────────────────────────────────────────────
  cat > "${INSTALL_PATH}/README.md" <<EOF
# 钉钉数字同事（DingTalk digital colleague）

backend 软件镜像 \`software:<os_tag>-dingtalk-dsh\`，把钉钉群聊接入 DSH Agent 运行时：
@ 机器人 → 消息进 DSH 常驻会话；简单任务触发叶子会话执行；结果引用回复到群里。

## 组件

| 组件 | 作用 | 安装 |
|------|------|------|
| DWS \`dingtalk-workspace-cli\` | 钉钉工作台 CLI：登录态 + 群消息通道 | 官方 install.sh，standalone 二进制 |
| DSH \`@deepseek-ai/dsh\` | DeepSeek Harness Agent 运行时（Node ≥ 24） | \`npm i -g\`（钉版本） |
| \`dingtalk-dsh-assistant\` | DSH 插件：钉钉群聊接入常驻会话 | \`dsh plugin --profile web add\`（bake 进种子） |

## 持久化（方案 C：默认路径 + 按目录挂卷）

不设 \`DSH_HOME\` / \`DWS_CONFIG_DIR\`，DSH/DWS 全部走运行用户 home 的默认路径。
需要持久化的五个目录，compose 逐个挂到 \`/deployment/accounts/sarmn/\` 下：

| 容器路径 | 内容 |
|----------|------|
| \`~/.dsh\` | DSH 数据域：会话/轨迹/插件配置（首次启动从种子拷入 assistant 插件） |
| \`~/.dws\` | DWS profiles / 技能状态 / \`skills/\`（首次启动从种子拷入技能） |
| \`~/.agents\` | \`skills/\`（multi 模式技能，首次启动从种子拷入） |
| \`~/.local/share/dws-cli\` | DWS 凭证库（dek + auth-token*.enc，登录态本体，**必须挂**） |
| \`~/.local/bin\` | \`dws\` standalone 二进制（首次启动从种子拷入） |

\`\`\`bash
docker run -d --name dingtalk-dsh \\
  -v dsh_home:/deployment/accounts/sarmn/.dsh \\
  -v dws_config:/deployment/accounts/sarmn/.dws \\
  -v dws_agents:/deployment/accounts/sarmn/.agents \\
  -v dws_creds:/deployment/accounts/sarmn/.local/share/dws-cli \\
  -v dws_bin:/deployment/accounts/sarmn/.local/bin \\
  -p 127.0.0.1:3080:3080 \\
  registry.cn-hangzhou.aliyuncs.com/sarmn/software:noble-dingtalk-dsh
\`\`\`

种子语义：挂卷里已有的内容**一律不覆盖**——只有目标缺失时才从镜像种子拷入。
所以换空卷 = 全新实例（自动补齐插件/技能/二进制）；老卷升级镜像 = 数据原样保留。

## dws upgrade（容器内升级持久）

dws 是 standalone 二进制，位于挂卷 \`~/.local/bin/dws\`（\`/deployment/bin/dws\` 是它的软链）。
\`dws upgrade\` 解析自身真实路径后**原地原子替换**卷内二进制——以 sarmn 身份执行即可，
升级结果随卷持久，容器重建不回退：

\`\`\`bash
docker exec -it -u sarmn dingtalk-dsh dws upgrade
\`\`\`

（对比：npm 安装的 dws upgrade 会委派包管理器写 \`/usr/local\`，sarmn 不可写、
且改动落在容器层随重建丢失——这是本镜像弃用 npm 装 dws 的原因。DSH 仍由镜像
钉版本管理，升级 DSH 请重建镜像。）

## 运行用户与 PUID/PGID

服务统一以 \`sarmn\` 用户常驻。默认 uid/gid 由 base 层 \`create_user sarmn\` 决定
（通常 1000）。挂载卷在宿主机上属主是别的 uid/gid 时，用 \`PUID\` / \`PGID\`
让运行期把 \`sarmn\` 的 uid/gid 对齐过去：

\`\`\`bash
docker run -d --name dingtalk-dsh -e PUID=\$(id -u) -e PGID=\$(id -g) ...
\`\`\`

对齐由 base 层 \`/etc/cont-init.d/05-puid-pgid\` 在所有 s6 服务启动前统一完成，
\`sarmn\` 的家目录不变（始终 \`/deployment/accounts/sarmn\`）。

## 首次登录

\`\`\`bash
# 一次性：弹出设备码，用钉钉扫码/访问链接完成登录。
# 以 sarmn 身份执行：凭证写进卷内 ~/.local/share/dws-cli，配置走默认 ~/.dws，
# 与服务进程读的是同一份（方案 C 无 DWS_CONFIG_DIR，不需要额外 -e）。
docker exec -it -u sarmn dingtalk-dsh dws auth login --device
\`\`\`

## 关键配置（对应需求）

- \`~/.dsh\`：按实例隔离的 DSH 数据域（每个数字同事实例独立一份；挂新卷即新实例，
  启动脚本自动从种子拷入 assistant 插件并装配 resident Runtime——设置页 dws
  状态来源，无需手工处理）。
  插件版本必须与镜像内 DSH 代际配对：2.x 插件依赖 dsh 0.2.x API，与 dsh 0.1.x
  不兼容（本镜像 bake 的是 DSH ${DSH_PIN_VERSION} + 插件 ${DSH_ASSISTANT_PIN_VERSION}）。
  注意：老卷里若存着 0.1.x 时代的 profile（\`profiles/web\`），种子不会覆盖——
  跨代际升级需先清掉卷内 \`profiles/web\` 与 \`storages/\` 让种子重新生成
  （2.x 任务会话架构与 1.0 存储格式不通用，官方也要求清洁启动）。
- \`~/.dws\`：DWS profiles（profiles.json）/ 技能状态 / \`skills/\`。
- \`~/.local/share/dws-cli\`：登录态本体（dek + auth-token*.enc），容器重建不丢。
- \`~/.agents/skills\` + \`~/.dws/skills\`：技能（multi 模式），运行期
  \`dws skill install\` 新装的技能直接落进挂卷。
- 插件权限：resident 主会话只读，leaf 任务会话拥有完整执行权限（在 DSH Web
  控制台 → Settings → Plugins → 钉钉个人助理 里配置）。
- \`@deepseek-ai/*\` 单副本：bake 与每次启动都会跑 \`dedup-dsh-packages.sh\`，把
  profile 插件侧与 dsh 运行时重叠的 @deepseek-ai 包 symlink 到运行时副本——不修
  则群消息收得到、工具一调就崩、机器人永远无回复（dsh-tools 的调度器 Symbol 跨
  副本失配；原理见 docs/dsh-dws修复方案/DEDUP-FIX.md）。
- \`dsh web\` 只监听 \`127.0.0.1:3080\`，\`--host 0.0.0.0\` 被 CLI 禁用。

## 验收

在钉钉群里 @ 机器人，验证三件事：① 消息入常驻会话；② 简单任务触发叶子会话执行；
③ 结果以引用回复形式回到群里。

## 参考资料

- DWS: https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli
- dingtalk-dsh-assistant: https://www.npmjs.com/package/dingtalk-dsh-assistant
- DSH: DeepSeek Harness 官方文档（\`@deepseek-ai/dsh\`）
EOF
}

autoExecuteFunc setEnv installDeps installDws installDsh installAssistant initS6Config
