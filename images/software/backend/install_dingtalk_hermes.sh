#!/bin/bash
###
 # Install 钉钉数字同事（hermes 版）—— backend 软件。
 #
 # 组件（对应需求，架构与本机已验证的 dingtalk-bridge.service 方案一致）：
 #   Hermes  NousResearch/hermes-agent  Agent 运行时（Python，官方 install.sh 自举 uv + venv）
 #   DWS     dingtalk-workspace-cli     钉钉工作台 CLI：登录态 + 消息通道（个人账号身份）
 #   桥接    dingtalk-bridge.py         群聊监控守护进程：spawn dws event +listen-im 订阅
 #          （at-me / 每群 group），按群策略（at_trigger/keywords/free_response/
 #          reply_mode/history_size）过滤后调 hermes chat 处理，dws chat +messages-send
 #          回群；带多轮上下文与自发消息回显防护。
 #          源码在仓库 images/software/backend/dingtalk-hermes-plugin/dingtalk-bridge/，
 #          由 Dockerfile COPY 进构建上下文，本脚本分发到镜像层与种子目录
 #   私聊    hermes 原生 dingtalk 平台（plugins/platforms/dingtalk，官方内置）：
 #          运行期在 ~/.hermes/.env 配 DINGTALK_CLIENT_ID/SECRET 即接入（企业内部
 #          应用 Stream 模式），不需要安装任何额外组件
 #
 # 安装顺序：
 #   1. 依赖：ca-certificates/curl/xz-utils/git/procps/file（无需 Node——dws 是独立
 #      二进制，hermes 自带 Python；对比 dingtalk-dsh 方案省掉整个 Node 24 自举）
 #   2. DWS：官方 install.sh 装 standalone 二进制（与 dingtalk-dsh 完全同路径：
 #      ~/.local/bin 挂卷 + upgrade 原地原子替换 → 容器内升级持久；登录态卷与
 #      dsh 方案共享，device 登录一次两边通用——但两套容器不得同时运行）
 #   3. Hermes：官方 scripts/install.sh 非交互安装（--non-interactive --skip-browser
 #      --skip-computer-use --dir <镜像层> --commit <sha>），代码+venv 全部落在镜像层，
 #      数据 home（~/.hermes）走卷；钉版本默认 v0.22.4
 #   4. dingtalk-bridge：分发到 $INSTALL_PATH/dingtalk-bridge/（镜像层权威副本，
 #      start 脚本直接从镜像层执行，升级镜像即下发修复）；种子配置 config.yaml 落
 #      $SEED_HOME/.local/state/dingtalk-bridge/（全新卷的初始内容，运行期只在
 #      卷内缺失时拷入，用户改过的群配置永不覆盖）
 #
 # 注：仓库里 dingtalk-hermes-plugin/dws-bridge/（hermes 平台插件形态）是早期方案，
 # 本机验证后已被 dingtalk-bridge 独立守护进程方案取代，本脚本不再安装它。
 #
 # Layer layout（同 dsh 方案 C：不设 HERMES_HOME 全局环境变量，运行期 start 脚本
 # 显式传；需要持久化的目录由 compose 按路径单独挂卷；bake 进这些路径的内容统一
 # 先落到 SEED_HOME，运行期 start 脚本在卷内缺失时拷入，已有内容一律不覆盖）：
 #   /deployment/accounts/sarmn/.hermes              # hermes 数据域：config.yaml/.env/会话/state.db
 #   /deployment/accounts/sarmn/.dws                 # DWS profiles/技能状态/技能（种子含技能）
 #   /deployment/accounts/sarmn/.agents/skills       # 技能（multi 模式，种子含）
 #   /deployment/accounts/sarmn/.local/share/dws-cli # DWS 凭证库（dek + auth-token*.enc）
 #   /deployment/accounts/sarmn/.local/bin/dws       # DWS standalone 二进制（种子含；upgrade 原地替换）
 #   /deployment/accounts/sarmn/.local/state/dingtalk-bridge  # 桥接 config.yaml + history.json + bridge.log
 #   /deployment/software/dingtalk-hermes/hermes-agent   # hermes 代码 + venv（镜像层，不挂卷）
 #   /deployment/software/dingtalk-hermes/dingtalk-bridge/ # 桥接权威副本（镜像层）
 #   /deployment/software/dingtalk-hermes/seed-home      # SEED_HOME：初始内容种子（镜像内，不挂卷）
 #   /deployment/bin/dingtalk-hermes-start.sh            # s6 longrun：hermes gateway
 #   /deployment/bin/dingtalk-bridge-start.sh            # s6 longrun：钉钉群桥
 #   /deployment/bin/hermes / dws                        # 启动器软链
 #
 # 构建期可覆盖（Dockerfile build-arg / 环境变量）：
 #   HERMES_PIN_VERSION  hermes 版本 tag（默认 v0.22.4；解析为 commit SHA 后传给
 #                       install.sh --commit；--commit 失败时回退 --channel stable，
 #                       实际版本以 hermes --version 为准写入 cont_env）
 #   DWS_PIN_VERSION     DWS 版本（默认 latest；可写 1.0.65 或 v1.0.65）
 #
 # Dockerfile 需要把桥接源码与固化的上游安装脚本 COPY 进构建上下文：
 #   COPY ./images/software/backend/dingtalk-hermes-plugin /tmp/dingtalk-hermes-plugin
 #   COPY ./images/software/backend/vendor /tmp/vendor
 #
 # 上游：
 #   Hermes  https://github.com/NousResearch/hermes-agent
 #   DWS     https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli
###
source /deployment/scripts/common.sh

check_target_arch(){
  ARCH=$(uname -m)
  case $ARCH in
      x86_64|amd64|aarch64|arm64)
          ;;
      *)
          echo "未知架构: $ARCH"
          exit 1
          ;;
  esac
  echo "目标架构: ${ARCH}"
}

setEnv(){
  check_target_arch
  export DEBIAN_FRONTEND=noninteractive
  export INSTALL_PATH=/deployment/software/dingtalk-hermes

  export HERMES_PIN_VERSION="${HERMES_PIN_VERSION:-v0.22.4}"
  export DWS_PIN_VERSION="${DWS_PIN_VERSION:-}"

  # 种子目录：bake 期所有要进挂卷的初始内容（hermes 数据域初始状态、dws 二进制、
  # 技能、桥接初始配置）都以 HOME=SEED_HOME 落到这里；运行期 start 脚本把卷内
  # 缺失的部分拷入。
  export SEED_HOME="${INSTALL_PATH}/seed-home"

  # 桥接源码 staging 路径（Dockerfile COPY 目的地）
  export BRIDGE_SRC=/tmp/dingtalk-hermes-plugin/dingtalk-bridge

  echo "Using Hermes ${HERMES_PIN_VERSION}"
}

installDeps(){
  export DEBIAN_FRONTEND=noninteractive
  pkg_update || return 1
  # file: install.sh 探测二进制格式用；procps: 运行期排查；git: install.sh clone 仓库
  pkg_install ca-certificates curl xz-utils git procps file || return 1
  pkg_clean
}

# 与 install_dingtalk_dsh.sh 的 installDws 完全一致（standalone 二进制 + 技能种子；
# 登录态卷两边共享，device 登录一次通用）。任何修改必须两边同步。
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

  # 安装脚本按 tag 拉取（与二进制同版本，保证可复现）；tag 上没有时回退 main。
  # raw.githubusercontent.com 在部分网络会超时甚至截断传输（curl 报错但留下非空
  # 残文件），因此每次下载后用 sh -n 校验语法完整性，不完整即换源重试；
  # api.github.com 的 raw media type 与 raw.githubusercontent.com 是同一份字节。
  local script=/tmp/dws-install.sh fetched=""
  rm -f "${script}"
  local ref url headers
  for ref in ${version:+"${version}"} main; do
    for url in \
      "https://raw.githubusercontent.com/DingTalk-Real-AI/dingtalk-workspace-cli/${ref}/scripts/install.sh" \
      "https://api.github.com/repos/DingTalk-Real-AI/dingtalk-workspace-cli/contents/scripts/install.sh?ref=${ref}"; do
      headers=()
      [[ "${url}" == https://api.github.com/* ]] && headers=(-H "Accept: application/vnd.github.raw")
      if curl -fsSL --connect-timeout 20 --max-time 90 "${headers[@]}" -o "${script}" "${url}" \
        && [ -s "${script}" ] && sh -n "${script}" 2>/dev/null; then
        fetched=1; break 2
      fi
      echo "DWS install.sh download incomplete/failed (${url}), trying next source" >&2
    done
  done
  [ -n "${fetched}" ] || { echo "Failed to download DWS install.sh" >&2; return 1; }

  local install_env=(HOME="${SEED_HOME}" DWS_INSTALL_DIR="${SEED_HOME}/.local/bin" DWS_SKILL_MODE=multi)
  [ -n "${version}" ] && install_env+=(DWS_VERSION="${version}")
  env "${install_env[@]}" sh "${script}" || { echo "Failed to install DWS (standalone)" >&2; return 1; }

  "${SEED_HOME}/.local/bin/dws" version || { echo "DWS binary missing or broken" >&2; return 1; }
  DWS_VERSION="$("${SEED_HOME}/.local/bin/dws" version 2>/dev/null | head -n 1 || echo "${version:-latest}")"
  export DWS_VERSION
  echo "DWS ${DWS_VERSION} installed (standalone, seeded at ${SEED_HOME}/.local/bin/dws)"
}

# 解析 hermes tag 对应的 commit SHA：优先 git ls-remote（无 API 限流），
 # 回退 GitHub API。宿主机 raw.githubusercontent.com 不可达的场景见下载回退。
resolveHermesSha(){
  local tag="$1" sha=""
  sha="$(git ls-remote https://github.com/NousResearch/hermes-agent.git "refs/tags/${tag}" 2>/dev/null \
    | awk 'NR==1{print $1}')" || sha=""
  if [ -z "${sha}" ]; then
    sha="$(curl -fsSL --connect-timeout 15 --max-time 45 \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/NousResearch/hermes-agent/git/refs/tags/${tag}" 2>/dev/null \
      | grep -o '"sha"[^,}]*' | head -n 1 | cut -d'"' -f4 || true)"
  fi
  [ -n "${sha}" ] || { echo "Failed to resolve hermes tag ${tag} to a commit SHA" >&2; return 1; }
  printf '%s' "${sha}"
}

installHermes(){
  mkdir -p /deployment/bin "${INSTALL_PATH}" "${SEED_HOME}"

  local tag="${HERMES_PIN_VERSION}"
  local sha
  sha="$(resolveHermesSha "${tag}")" || return 1
  echo "Hermes ${tag} -> ${sha}"

  # 官方安装脚本：v0.22.4 已固化进仓库（供应链 pin，vendor/hermes-agent/install.sh，
  # 上游 commit 64dbae64747ab640a3fece06f359307c30d129da，2026-10-25 经
  # api.github.com raw 拉取，sha256 如下）。pin 为 v0.22.4 时优先用固化副本并做
  # sha256 校验；其他 pin 版本仍按 SHA 现拉。raw.githubusercontent.com 在部分网络
  # 不可达或截断传输（curl 报错但留下非空残文件），每次下载后用 bash -n 校验语法
  # 完整性，不完整即换源；api.github.com 的 raw media type 是同一份字节。
  local vendored="/tmp/vendor/hermes-agent/install.sh"
  local vendored_sha256="20f44240ebada354a468104a6a6724d037afcb8883d4d09ddeb4815622c52d8b"
  local script=/tmp/hermes-install.sh fetched=""
  rm -f "${script}"
  if [ "${tag}" = "v0.22.4" ] && [ -s "${vendored}" ]; then
    if echo "${vendored_sha256}  ${vendored}" | sha256sum -c - >/dev/null 2>&1 \
      && bash -n "${vendored}" 2>/dev/null; then
      cp "${vendored}" "${script}"; fetched=1
      echo "hermes install.sh: vendored copy (sha256 verified)"
    else
      echo "vendored hermes install.sh failed sha256/syntax check, falling back to download" >&2
    fi
  fi
  if [ -z "${fetched}" ]; then
  local url headers
  for url in \
    "https://raw.githubusercontent.com/NousResearch/hermes-agent/${sha}/scripts/install.sh" \
    "https://api.github.com/repos/NousResearch/hermes-agent/contents/scripts/install.sh?ref=${sha}"; do
    headers=()
    [[ "${url}" == https://api.github.com/* ]] && headers=(-H "Accept: application/vnd.github.raw")
    if curl -fsSL --connect-timeout 20 --max-time 90 "${headers[@]}" -o "${script}" "${url}" \
      && [ -s "${script}" ] && bash -n "${script}" 2>/dev/null; then
      fetched=1; break
    fi
    echo "hermes install.sh download incomplete/failed (${url}), trying next source" >&2
  done
  fi
  [ -n "${fetched}" ] || { echo "Failed to download hermes install.sh" >&2; return 1; }

  # 非交互安装：代码+venv 落镜像层（--dir），数据 home 落种子（--hermes-home）。
  # --skip-browser/--skip-computer-use：backend 容器无桌面，不装浏览器与 computer-use。
  local install_env=(
    HOME="${SEED_HOME}"
    HERMES_HOME="${SEED_HOME}/.hermes"
    HERMES_INSTALL_DIR="${INSTALL_PATH}/hermes-agent"
  )
  if ! env "${install_env[@]}" bash "${script}" \
        --non-interactive --skip-browser --skip-computer-use \
        --dir "${INSTALL_PATH}/hermes-agent" --hermes-home "${SEED_HOME}/.hermes" \
        --commit "${sha}"; then
    # --commit 要求该提交是 main 祖先（R2）；失败时回退 stable 渠道，实际版本以
    # hermes --version 为准（写进 cont_env，与钉版本不符时构建日志可见）
    echo "hermes install.sh --commit ${sha} failed, falling back to --channel stable" >&2
    env "${install_env[@]}" bash "${script}" \
      --non-interactive --skip-browser --skip-computer-use \
      --dir "${INSTALL_PATH}/hermes-agent" --hermes-home "${SEED_HOME}/.hermes" \
      --channel stable || { echo "Failed to install hermes (both --commit and --channel stable)" >&2; return 1; }
  fi

  # ── 定位 hermes 启动器（venv 布局由 install.sh 决定，逐候选探测）──────────
  # 官方 install.sh 以 "$INSTALL_DIR/.hermes/bin/hermes" 为真实入口（安装期生成，
  # 带 venv python shebang）；~/.local/bin/hermes 只是 bash 包装脚本，放最后兜底。
  local launcher="" cand
  for cand in \
    "${INSTALL_PATH}/hermes-agent/.hermes/bin/hermes" \
    "${INSTALL_PATH}/hermes-agent/venv/bin/hermes" \
    "${INSTALL_PATH}/hermes-agent/.venv/bin/hermes" \
    "${SEED_HOME}/.hermes/bin/hermes" \
    "${SEED_HOME}/.local/bin/hermes"; do
    if [ -x "${cand}" ]; then launcher="${cand}"; break; fi
  done
  if [ -z "${launcher}" ]; then
    launcher="$(find "${INSTALL_PATH}" -maxdepth 5 \( -type f -o -type l \) -name hermes -perm -u+x 2>/dev/null | head -n 1)"
  fi
  [ -n "${launcher}" ] || { echo "hermes launcher not found after install" >&2; return 1; }
  echo "hermes launcher: ${launcher}"
  ln -sfn "${launcher}" /deployment/bin/hermes
  export HERMES_LAUNCHER="${launcher}"

  # 冒烟：--version 必须能跑（venv 解释器 + 依赖完整性的最低验证）
  env HOME="${SEED_HOME}" HERMES_HOME="${SEED_HOME}/.hermes" "${launcher}" --version || {
    echo "hermes --version failed" >&2; return 1; }
  HERMES_VERSION="$(env HOME="${SEED_HOME}" HERMES_HOME="${SEED_HOME}/.hermes" \
    "${launcher}" --version 2>/dev/null | head -n 1 || echo "${tag}")"
  export HERMES_VERSION
  echo "Hermes version: ${HERMES_VERSION}"

  # ── venv sqlite 版本断言（WAL bug #70480，需 >= 3.51.3）──────────────────
  # state.db 用 WAL 模式；sqlite < 3.51.3 的 WAL bug 会损坏库文件。不达标直接让
  # 构建失败（回退方案：仿 upstream Dockerfile 多阶段编译 sqlite 3.53.4 打进 venv）。
  local venv_py="" shebang_py
  # 启动器可能是 sh/bash 包装脚本而非 python 脚本（shebang 为 /usr/bin/env bash 之类），
  # 只有 shebang 明确指向 python 解释器时才采用，否则 /bin/sh -c 'import ...' 会语法爆炸。
  shebang_py="$(head -n 1 "${launcher}" | sed -n 's/^#!\([^ ]*\).*/\1/p')"
  case "${shebang_py}" in
    *python*) [ -x "${shebang_py}" ] && venv_py="${shebang_py}" ;;
  esac
  if [ -z "${venv_py}" ]; then
    # 包装脚本通常在 exec 行引用 venv 的真实 python，形如（引号可有可无）：
    #   exec "/.../venv/bin/python" "/.../hermes" "$@"
    #   exec /.../tools/python-3.14.7+.../bin/python3 -I -c '...'
    venv_py="$(sed -n 's|^exec ["'"'"']\?\([^"'"'"' ]*bin/python[0-9.]*\)["'"'"']\? .*|\1|p' "${launcher}" | head -n 1)"
    { [ -n "${venv_py}" ] && [ -x "${venv_py}" ]; } || venv_py=""
  fi
  if [ -z "${venv_py}" ]; then
    for cand in \
      "${INSTALL_PATH}/hermes-agent/.hermes/venv/bin/python" \
      "${INSTALL_PATH}/hermes-agent/venv/bin/python" \
      "${INSTALL_PATH}/hermes-agent/.venv/bin/python" \
      "${SEED_HOME}/.hermes/hermes-agent/venv/bin/python" \
      "${SEED_HOME}/.hermes/venv/bin/python" \
      ${SEED_HOME}/.hermes/tools/*/bin/python3; do
      if [ -x "${cand}" ]; then venv_py="${cand}"; break; fi
    done
  fi
  [ -n "${venv_py}" ] || {
    echo "DEBUG launcher content (first 8 lines):" >&2
    head -n 8 "${launcher}" >&2 || true
    echo "DEBUG python interpreters under install/seed dirs:" >&2
    find "${INSTALL_PATH}" "${SEED_HOME}" -maxdepth 7 \( -type f -o -type l \) \
      \( -name "python" -o -name "python3" -o -name "python3.*" \) 2>/dev/null | head -n 20 >&2
    echo "hermes venv python not found" >&2; return 1; }
  export HERMES_VENV_PYTHON="${venv_py}"
  local sqlite_ver
  sqlite_ver="$("${venv_py}" -c 'import sqlite3; print(sqlite3.sqlite_version)')" || {
    echo "failed to probe venv sqlite version" >&2; return 1; }
  echo "hermes venv sqlite: ${sqlite_ver} (python: ${venv_py})"
  if [ "$(printf '%s\n' "3.51.3" "${sqlite_ver}" | sort -V | head -n 1)" != "3.51.3" ]; then
    echo "FATAL: hermes venv sqlite ${sqlite_ver} < 3.51.3 (WAL bug #70480 would corrupt state.db)" >&2
    return 1
  fi
}

installDingtalkBridge(){
  [ -f "${BRIDGE_SRC}/dingtalk-bridge.py" ] || {
    echo "dingtalk-bridge source missing at ${BRIDGE_SRC} (Dockerfile must COPY dingtalk-hermes-plugin)" >&2
    return 1
  }

  # 镜像层权威副本：start 脚本直接从镜像层执行（升级镜像即下发桥接修复；
  # 要定制就改仓库源码重建镜像，不要在卷里改）
  mkdir -p "${INSTALL_PATH}/dingtalk-bridge"
  rm -rf "${INSTALL_PATH}/dingtalk-bridge"
  cp -a "${BRIDGE_SRC}" "${INSTALL_PATH}/dingtalk-bridge"
  rm -rf "${INSTALL_PATH}/dingtalk-bridge/__pycache__"
  chmod 0755 "${INSTALL_PATH}/dingtalk-bridge/dingtalk-bridge.py"

  # 种子配置：全新卷的初始 config.yaml（空群列表 + 字段注释）。运行期 start 脚本
  # 只在卷内缺失时拷入——用户改过的群配置永不覆盖。groups 为空时桥接进程空转
  # （30 秒重检一次配置），配好群后无需重启容器，订阅循环重建即生效。
  mkdir -p "${SEED_HOME}/.local/state/dingtalk-bridge"
  cat > "${SEED_HOME}/.local/state/dingtalk-bridge/config.yaml" <<'EOF'
# 钉钉桥接策略配置
# groups 每群独立配置；self_chat 已废弃（钉钉「我」会话不产生 IM 事件，事件驱动不可行）。
#
# self_open_id: 本人的 openDingTalkId。配置后 @ 触发只响应「本人发的 @ 消息」。
#
# 字段说明（group）：
#   id            群的 openConversationId（dws chat +chat-search --query <名> 查）
#   name          群名（仅日志/展示）
#   at_trigger    true 时群里有人 @ 我 才响应（仅本人）
#   keywords      关键词触发列表：命中任一即响应（无需 @）；[] 不启用
#   free_response true 时群里每条消息都触发（适合单人群，无需 @/关键词）
#   reply_mode    group(回群) | dm(私聊发消息的人)
#   history_size  多轮上下文窗口（最近消息条数，按群共享）

self_open_id: ""

self_chat:
  enabled: false
  conversation_id: ""
  history_size: 20

groups: []
#  - id: cidXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX==
#    name: "机器人测试"
#    at_trigger: true
#    keywords: ["@小助手"]
#    reply_mode: group
#    history_size: 10
EOF

  # 语法冒烟 + PyYAML 断言（bridge 唯一第三方依赖，复用 hermes venv 的解释器运行；
  # bake 期不过直接让构建失败，不带病出厂）
  "${HERMES_VENV_PYTHON}" -m py_compile "${INSTALL_PATH}/dingtalk-bridge/dingtalk-bridge.py" || {
    echo "dingtalk-bridge.py 语法检查失败" >&2; return 1; }
  if ! "${HERMES_VENV_PYTHON}" -c 'import yaml' 2>/dev/null; then
    # 缺 PyYAML 就用 uv 装进 hermes 运行时 python（--python 精确指定解释器，
    # 不碰系统 python）。uv 由 hermes install.sh 自举，通常在 SEED_HOME/.local/bin。
    local uv_bin="" cand
    for cand in "${SEED_HOME}/.local/bin/uv" \
                "${SEED_HOME}/.hermes/tools/uv/uv" \
                "${INSTALL_PATH}/hermes-agent/.hermes/bin/uv"; do
      [ -x "${cand}" ] && { uv_bin="${cand}"; break; }
    done
    [ -n "${uv_bin}" ] || uv_bin="$(command -v uv || true)"
    [ -n "${uv_bin}" ] || { echo "uv not found，无法安装 PyYAML" >&2; return 1; }
    "${uv_bin}" pip install --python "${HERMES_VENV_PYTHON}" pyyaml || {
      echo "PyYAML 安装失败（python: ${HERMES_VENV_PYTHON}）" >&2; return 1; }
  fi
  "${HERMES_VENV_PYTHON}" -c 'import yaml' || {
    echo "hermes venv 缺 PyYAML，dingtalk-bridge 无法运行" >&2; return 1; }

  echo "dingtalk-bridge installed (image: ${INSTALL_PATH}/dingtalk-bridge, seed config: ${SEED_HOME}/.local/state/dingtalk-bridge/config.yaml)"
}

# ── hermes 种子归位：路径改写 + 瞬态锁清理 ───────────────────────────────
# bake 以 HOME=SEED_HOME 跑官方 install.sh，hermes 的安装注册表
# （installs/<hash>/facts.json、venv pyvenv.cfg、editable finder、direct_url.json、
# source-checks 等文本文件）会把 SEED_HOME 路径烧进去；运行期 HERMES_HOME 是
# 挂卷后的 ~/.hermes（/deployment/accounts/sarmn/.hermes），路径不匹配会被
# hermes 判为 "dependency environment is missing or outside this install" 并进入
# 修复重试循环（本机 soak 实测，改写后消除）。
# 这里把种子内所有提到 SEED_HOME 的文本文件统一改写为运行期 home：grep -rlI 全量
# 扫描（-I 跳过二进制；.pyc/msgpack 缓存里的路径无害，python 按源文件 mtime 重新
# 校验），不枚举文件清单——上游版本增减文件时不会漏。
# 注意改写范围只限 SEED_HOME 树：镜像层启动器
# $INSTALL_PATH/hermes-agent/.hermes/bin/hermes 必须继续指向 SEED_HOME 下的
# tools python（镜像层只读常驻，不挂卷也在）。
#
# 瞬态锁/修复标记不进出厂：.repair-incomplete 里的重试计数器会让全新卷第一次启动
# 就直接撞 "automatic dependency repair retry limit reached"（soak 实测踩过）。
# 只删点号瞬态文件/目录；uv.lock 是依赖清单（不是进程锁），绝不删。
# 调用顺序必须在 installDingtalkBridge 之后：uv pip install pyyaml 可能往种子里
# 新写带 SEED_HOME 路径的 RECORD 文件，一并扫掉。
sanitizeHermesSeed(){
  local seed_hermes="${SEED_HOME}/.hermes"
  local runtime_home="/deployment/accounts/sarmn"
  [ -d "${seed_hermes}" ] || { echo "hermes seed missing at ${seed_hermes}" >&2; return 1; }

  local f count=0
  while IFS= read -r f; do
    sed -i "s|${SEED_HOME}|${runtime_home}|g" "${f}"
    count=$((count + 1))
  done < <(grep -rlI -- "${SEED_HOME}" "${SEED_HOME}")
  echo "hermes seed path rewrite: ${count} file(s) ${SEED_HOME} -> ${runtime_home}"
  [ "${count}" -gt 0 ] || echo "WARN: no seed files referenced ${SEED_HOME} (unexpected)" >&2

  find "${seed_hermes}" \( \
      -name '.update-incomplete' -o -name '.lazy-refresh-incomplete' -o \
      -name '.repair-incomplete' -o -name '.install.lock' -o \
      -name '.recovery.lock' -o -name '.prepare.lock' -o \
      -name '.pm-write.lock' -o -name '.hermes-update-in-progress.lock' -o \
      -name '.lease-managed' -o -name '.leases' \
    \) -exec rm -rf {} +
  echo "hermes seed sanitized (transient locks/markers removed)"
}

initS6Config(){
  mkdir -p "${INSTALL_PATH}"

  # 种子整目录收归 sarmn：start 脚本用 cp -r（非 cp -a，原因见 start 脚本注释）拷进
  # 卷后由 chown -R 归位属主
  chown -R sarmn:sarmn "${INSTALL_PATH}" 2>/dev/null || true

  # ── s6 longrun 的 run body：hermes gateway ─────────────────────────────
  # run body 以 root 启动（register_s6_longrun_cmd 不传 run_user），先在 root 态完成
  # 种子拷贝 + 属主修正，再 setuidgid 切到 sarmn 前台常驻 hermes gateway；重启语义
  # 交给 s6。PUID/PGID 的 uid/gid 对齐由 base 层 /etc/cont-init.d/05-puid-pgid 在
  # 服务启动前统一完成，此处不再重复。
  cat > /deployment/bin/dingtalk-hermes-start.sh <<EOF
#!/bin/bash
set -e

RUN_USER="sarmn"
HOME_DIR="\$(getent passwd "\${RUN_USER}" | cut -d: -f6)"
[ -n "\${HOME_DIR}" ] || HOME_DIR="/deployment/accounts/\${RUN_USER}"
SEED_HOME="${INSTALL_PATH}/seed-home"
HERMES_LAUNCHER="${HERMES_LAUNCHER}"

# 持久化点（compose 按目录单独挂卷；未挂的目录随容器重建丢失。凭证库必须挂）
mkdir -p "\${HOME_DIR}/.hermes" "\${HOME_DIR}/.dws" "\${HOME_DIR}/.agents" \\
         "\${HOME_DIR}/.local/share/dws-cli" "\${HOME_DIR}/.local/bin" \\
         "\${HOME_DIR}/.local/state/dingtalk-bridge"

# 权限收紧：hermes 数据域（.env 含 LLM key 与 DINGTALK_CLIENT_SECRET）与 DWS 凭证库
# （dek + auth-token*.enc）
chmod 700 "\${HOME_DIR}/.hermes" "\${HOME_DIR}/.local/share/dws-cli" 2>/dev/null || true

# 种子拷贝：镜像 bake 的初始状态只在目标缺失时拷入——卷里已有的内容
# （升级过的 dws 二进制、用户改过的配置/技能/桥接群配置）一律不被种子覆盖。
# 用 cp -r 不用 cp -a：卷在 exFAT 上时 -a 保留属主/权限的 syscall 直接 EPERM，
# 会打死 set -e；属主由后面的 chown -R 兜底（exFAT 上 chown 是 no-op，靠挂载
# uid= 与 PUID/PGID 对齐）。
if [ ! -e "\${HOME_DIR}/.hermes/config.yaml" ] && [ -d "\${SEED_HOME}/.hermes" ]; then
  cp -r "\${SEED_HOME}/.hermes/." "\${HOME_DIR}/.hermes/"
fi
if [ ! -e "\${HOME_DIR}/.dws/skills" ] && [ -d "\${SEED_HOME}/.dws" ]; then
  cp -r "\${SEED_HOME}/.dws/." "\${HOME_DIR}/.dws/"
fi
if [ ! -e "\${HOME_DIR}/.agents/skills" ] && [ -d "\${SEED_HOME}/.agents" ]; then
  cp -r "\${SEED_HOME}/.agents/." "\${HOME_DIR}/.agents/"
fi
if [ ! -x "\${HOME_DIR}/.local/bin/dws" ] && [ -f "\${SEED_HOME}/.local/bin/dws" ]; then
  cp -r "\${SEED_HOME}/.local/bin/dws" "\${HOME_DIR}/.local/bin/dws"
fi
if [ ! -e "\${HOME_DIR}/.local/state/dingtalk-bridge/config.yaml" ] && \\
   [ -d "\${SEED_HOME}/.local/state/dingtalk-bridge" ]; then
  cp -r "\${SEED_HOME}/.local/state/dingtalk-bridge/." "\${HOME_DIR}/.local/state/dingtalk-bridge/"
fi

# dws 与 hermes 上 PATH（/deployment/bin 在镜像 ENV PATH 最前）。standalone 的
# dws upgrade 原地原子替换卷内二进制 → 升级持久；hermes 启动器在镜像层，随镜像更新。
ln -sfn "\${HOME_DIR}/.local/bin/dws" /deployment/bin/dws
ln -sfn "\${HERMES_LAUNCHER}" /deployment/bin/hermes

# 重 chown 家目录：PUID/PGID 改过 sarmn 的 uid/gid 后，bake/旧卷里的旧属主文件
# 新 sarmn 读写不了（种子刚拷出来的文件也一并归位）
chown -R "\${RUN_USER}:\${RUN_USER}" "\${HOME_DIR}" 2>/dev/null || true
[ -f "\${HOME_DIR}/.hermes/.env" ] && chmod 600 "\${HOME_DIR}/.hermes/.env" || true

# DWS 登录态自检：凭证库为空 = 尚未登录，只提醒，不阻断 hermes 起服务。
# 登录（与 dingtalk-dsh 同一套凭证卷，device 登录一次两边通用）：
#   docker exec -it -u sarmn <container> dws auth login --device
if ! ls "\${HOME_DIR}/.local/share/dws-cli"/auth-token*.enc >/dev/null 2>&1; then
  echo "[dingtalk-hermes] 未检测到 DWS 登录态（dws-cli 凭证库为空）；请先执行: docker exec -it -u \${RUN_USER} <container> dws auth login --device" >&2
fi

# LLM key 预检（非阻断）：hermes 的 provider 在运行期配置（~/.hermes/.env）。
# 没有任何 *_API_KEY 时 gateway 仍可启动但所有会话都会失败，打响亮警告。
if ! grep -qE '^[A-Za-z_][A-Za-z0-9_]*API_KEY=.+' "\${HOME_DIR}/.hermes/.env" 2>/dev/null; then
  echo "[dingtalk-hermes] WARNING: \${HOME_DIR}/.hermes/.env 未配置任何 LLM API key；请编辑该文件（如 DEEPSEEK_API_KEY/OPENAI_API_KEY/ANTHROPIC_API_KEY）后重启容器" >&2
fi

# s6-setuidgid 不改 HOME（仍是 root 的）；dws 凭证走 XDG（\$HOME/.local/share/dws-cli）、
# hermes 数据域走 HERMES_HOME——不把 HOME 归位到运行用户，服务永远读不到登录态与配置。
# --no-supervise 必须带：hermes 检测到 s6 环境会把裸 gateway run 重定向为自注册
# /run/service/gateway-default 槽位，非 root 写 /run/service 直接 EPERM 崩溃循环；
# 我们自己的 s6 longrun 已经在 supervise，hermes 的自注册必须关掉。
exec s6-setuidgid "\${RUN_USER}" env HOME="\${HOME_DIR}" HERMES_HOME="\${HOME_DIR}/.hermes" "\${HERMES_LAUNCHER}" gateway run --no-supervise
EOF
  chmod 0755 /deployment/bin/dingtalk-hermes-start.sh

  # ── s6 longrun 的 run body：钉钉群桥 ───────────────────────────────────
  # 与 hermes gateway 平行的第二个常驻服务（对应本机 dingtalk-bridge.service）。
  # 桥接进程与 gateway 无进程间依赖（它调的是 hermes chat CLI 一次性会话），
  # 但同样以 root 起、做完种子/属主修正后 setuidgid 切到 sarmn。两个 start 脚本
  # 都能独立完成 dws 二进制种子拷贝与软链（s6 并行启动，无先后保证）。
  cat > /deployment/bin/dingtalk-bridge-start.sh <<EOF
#!/bin/bash
set -e

RUN_USER="sarmn"
HOME_DIR="\$(getent passwd "\${RUN_USER}" | cut -d: -f6)"
[ -n "\${HOME_DIR}" ] || HOME_DIR="/deployment/accounts/\${RUN_USER}"
SEED_HOME="${INSTALL_PATH}/seed-home"
INSTALL_PATH="${INSTALL_PATH}"
HERMES_LAUNCHER="${HERMES_LAUNCHER}"

mkdir -p "\${HOME_DIR}/.local/state/dingtalk-bridge" "\${HOME_DIR}/.local/bin" \\
         "\${HOME_DIR}/.local/share/dws-cli"

# dws 二进制与桥接配置的种子拷贝（与 hermes start 脚本同样的种子语义，幂等；
# 同样用 cp -r 而非 cp -a——exFAT 卷上 -a 的 chown/chmod EPERM 会打死 set -e）
if [ ! -x "\${HOME_DIR}/.local/bin/dws" ] && [ -f "\${SEED_HOME}/.local/bin/dws" ]; then
  cp -r "\${SEED_HOME}/.local/bin/dws" "\${HOME_DIR}/.local/bin/dws"
fi
if [ ! -e "\${HOME_DIR}/.local/state/dingtalk-bridge/config.yaml" ] && \\
   [ -d "\${SEED_HOME}/.local/state/dingtalk-bridge" ]; then
  cp -r "\${SEED_HOME}/.local/state/dingtalk-bridge/." "\${HOME_DIR}/.local/state/dingtalk-bridge/"
fi
ln -sfn "\${HOME_DIR}/.local/bin/dws" /deployment/bin/dws

chown -R "\${RUN_USER}:\${RUN_USER}" "\${HOME_DIR}/.local" 2>/dev/null || true

# bridge 唯一第三方依赖是 PyYAML——直接复用 hermes venv 的解释器（bake 期已断言
# 可 import yaml），不为它再装一份系统 python3-yaml
BRIDGE_PY=""
for cand in "${HERMES_VENV_PYTHON}" \\
            "\${INSTALL_PATH}/hermes-agent/venv/bin/python" \\
            "\${INSTALL_PATH}/hermes-agent/.venv/bin/python"; do
  if [ -x "\${cand}" ]; then BRIDGE_PY="\${cand}"; break; fi
done
[ -n "\${BRIDGE_PY}" ] || BRIDGE_PY="python3"

# DWS 登录态自检（非阻断）：未登录时桥接的 auth 检查循环会自己每分钟重试并打日志
if ! ls "\${HOME_DIR}/.local/share/dws-cli"/auth-token*.enc >/dev/null 2>&1; then
  echo "[dingtalk-bridge] 未检测到 DWS 登录态；请先执行: docker exec -it -u \${RUN_USER} <container> dws auth login --device" >&2
fi

# DWS_BIN/HERMES_BIN 显式传给桥接（它 also 支持 PATH 查找与 ~/.local/bin 回退，
# 显式传避免任何 PATH 歧义）；桥接配置/历史/日志全在 \$HOME/.local/state/dingtalk-bridge
exec s6-setuidgid "\${RUN_USER}" env HOME="\${HOME_DIR}" \\
  PATH="/deployment/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \\
  DWS_BIN="/deployment/bin/dws" HERMES_BIN="\${HERMES_LAUNCHER}" \\
  "\${BRIDGE_PY}" "\${INSTALL_PATH}/dingtalk-bridge/dingtalk-bridge.py"
EOF
  chmod 0755 /deployment/bin/dingtalk-bridge-start.sh

  # ── 运行期环境持久化（s6 with-contenv 会注入）────────────────────────
  write_cont_env HERMES_PIN_VERSION "${HERMES_PIN_VERSION}"
  write_cont_env HERMES_VERSION "${HERMES_VERSION}"
  write_cont_env DWS_VERSION "${DWS_VERSION}"

  echo "export PATH=/deployment/bin:\$PATH" >> /etc/environment

  # 注册常驻服务：run body 以 root 起，属主修正后 setuidgid 切到 sarmn 常驻
  register_s6_longrun_cmd dingtalk-hermes "exec /bin/bash /deployment/bin/dingtalk-hermes-start.sh"
  register_s6_longrun_cmd dingtalk-bridge "exec /bin/bash /deployment/bin/dingtalk-bridge-start.sh"

  # ── README ────────────────────────────────────────────────────────────
  cat > "${INSTALL_PATH}/README.md" <<EOF
# 钉钉数字同事（hermes 版）

backend 软件镜像 \`software:<os_tag>-dingtalk-hermes\`：Hermes Agent 运行时 +
钉钉群桥守护进程，把钉钉消息接入 hermes。与 dingtalk-dsh 镜像**并存**——
回退 = 换回 dsh tag。架构与本机已验证的 dingtalk-bridge.service 方案一致。

## 组件

| 组件 | 作用 | 安装 |
|------|------|------|
| Hermes \`NousResearch/hermes-agent\` | Agent 运行时（前台 \`hermes gateway run\`） | 官方 scripts/install.sh（钉版本，commit 锁定） |
| DWS \`dingtalk-workspace-cli\` | 钉钉工作台 CLI：登录态 + 消息通道（个人账号身份） | 官方 install.sh，standalone 二进制（与 dsh 镜像同源） |
| \`dingtalk-bridge.py\` | 群聊监控桥：dws event 订阅 → hermes chat → dws 回群 | 镜像层权威副本，s6 常驻 |
| hermes 原生 dingtalk 平台 | 私聊（企业内部应用 Stream 模式） | 官方内置，运行期 .env 配置 |

两个 s6 常驻服务：\`dingtalk-hermes\`（gateway，承载原生 dingtalk 平台私聊）与
\`dingtalk-bridge\`（群聊监控桥）。群桥调 \`hermes chat\` 一次性会话处理消息，
与 gateway 无进程间依赖。

## 持久化（同 dsh 方案 C：默认路径 + 按目录挂卷）

| 容器路径 | 内容 |
|----------|------|
| \`~/.hermes\` | hermes 数据域：config.yaml / .env（LLM key、DINGTALK_CLIENT_SECRET）/ 会话 / state.db |
| \`~/.dws\` | DWS profiles / 技能状态 / \`skills/\`（首次启动从种子拷入） |
| \`~/.agents\` | \`skills/\`（multi 模式技能，首次启动从种子拷入） |
| \`~/.local/share/dws-cli\` | DWS 凭证库（登录态本体，**必须挂**；与 dsh 容器共享同一卷） |
| \`~/.local/bin\` | \`dws\` standalone 二进制（首次启动从种子拷入） |
| \`~/.local/state/dingtalk-bridge\` | 群桥 \`config.yaml\`（群策略）+ \`history.json\`（多轮上下文）+ \`bridge.log\` |

\`\`\`bash
docker run -d --name dingtalk-hermes \\
  -v hermes_home:/deployment/accounts/sarmn/.hermes \\
  -v dws_config:/deployment/accounts/sarmn/.dws \\
  -v dws_agents:/deployment/accounts/sarmn/.agents \\
  -v dws_creds:/deployment/accounts/sarmn/.local/share/dws-cli \\
  -v dws_bin:/deployment/accounts/sarmn/.local/bin \\
  -v dt_bridge:/deployment/accounts/sarmn/.local/state/dingtalk-bridge \\
  registry.cn-hangzhou.aliyuncs.com/sarmn/software:noble-dingtalk-hermes
\`\`\`

**警告：dsh 与 hermes 两套容器不得同时挂同一套 dws 卷运行**——两边都是同一
钉钉消息流的消费者，会重复应答。迁移时先停 dsh 容器再启 hermes 容器。

## 配置（运行期，全部走卷，不随镜像重建丢失）

- \`~/.hermes/.env\`：LLM provider key（如 \`DEEPSEEK_API_KEY=...\`）+ 模型选择。
  镜像不内置任何 provider 配置；未配置时启动日志有警告，会话会失败但服务存活。
- 私聊（hermes 原生 dingtalk 平台）：同一 .env 里加
  \`DINGTALK_CLIENT_ID\` / \`DINGTALK_CLIENT_SECRET\`（企业内部应用，
  https://open-dev.dingtalk.com 创建，Stream 模式）。可选：
  \`DINGTALK_ALLOWED_USERS\`（staffId 白名单，\`*\` = 任何人）、
  \`DINGTALK_HOME_CHANNEL\`（cron/通知投递会话）。
- 群聊（群桥）：\`~/.local/state/dingtalk-bridge/config.yaml\`，每群独立策略：

\`\`\`yaml
self_open_id: "<本人 openDingTalkId>"   # 配了之后 @ 触发只响应本人发的 @
groups:
  - id: "<群 openConversationId>"        # dws chat +chat-search --query <群名> 查
    name: "机器人测试"
    at_trigger: true                     # 群里 @ 我才响应
    keywords: ["@小助手"]                 # 或命中关键词即响应
    free_response: false                 # true = 每条消息都触发（适合单人群）
    reply_mode: group                    # group 回群 | dm 私聊发消息的人
    history_size: 10                     # 多轮上下文窗口（按群共享）
\`\`\`

  \`groups\` 为空时桥接空转（30 秒重检一次配置），改完配置无需重启容器，
  订阅循环重建即生效。桥接环境变量（s6 service 里可加，一般不 need）：
  \`DT_BRIDGE_HERMES_TIMEOUT\`（默认 300s）、\`DT_BRIDGE_MAX_REPLY_LEN\`（默认 3000）、
  \`DT_BRIDGE_AT_SENDER\`（默认 1，回复时 @ 提问人）。

## 首次登录与上线步骤

\`\`\`bash
# 1. dws 登录（与 dsh 共用凭证卷，已登录过则跳过）
docker exec -it -u sarmn dingtalk-hermes dws auth login --device

# 2. 写 LLM key（+ 可选 DINGTALK_CLIENT_ID/SECRET）到卷内 .env
#    （host 上编辑 hermes_home 卷里的 .env）

# 3. 编辑群桥 config.yaml 加入要监控的群（groups 为空时桥接空转不订阅）

# 4. 重启容器：docker restart dingtalk-hermes
\`\`\`

## dws upgrade（容器内升级持久）

\`\`\`bash
docker exec -it -u sarmn dingtalk-hermes dws upgrade
\`\`\`

hermes 本体由镜像钉版本管理（本镜像：${HERMES_PIN_VERSION}），升级请重建镜像。

## 运行用户与 PUID/PGID

服务统一以 \`sarmn\` 用户常驻。\`PUID\`/\`PGID\` 对齐由 base 层
\`/etc/cont-init.d/05-puid-pgid\` 在所有 s6 服务启动前统一完成。

## 宿主机文件系统约束（实测）

- **\`~/.hermes\` 卷必须落在 POSIX 文件系统**（ext4/xfs 等）：hermes gateway 启动时
  必须 bind 一个 unix 控制套接字 \$HERMES_HOME/gateway.sock，exFAT 不支持 unix
  socket（bind 直接 EPERM），gateway 以 \`control listener unavailable\` 致命退出。
  宿主机 /deployment 是 exFAT 时，把该卷改挂到 ext4 路径
  （如 \`/var/lib/dingtalk-hermes/hermes\`）。
- 其余卷（\`.dws\` / \`.agents\` / \`.local/...\` / 桥接 state）可以放在 exFAT 上
  （sqlite WAL 实测可用，只有 unix socket 不行）。
- exFAT 卷不支持 chown/chmod：务必用 \`-e PUID=<host uid> -e PGID=<host gid>\`
  把容器内 sarmn 的 uid/gid 对齐到挂载属主（exFAT 挂载通常 uid=1000），否则
  容器内 sarmn(默认 1001) 写不了卷。
- \`.env\` 的 \`chmod 600\` 在 exFAT 上无效（fmask 强制 755），LLM key 对宿主机
  本地用户可读——这是 exFAT 的固有限制；敏感环境把 \`.hermes\` 卷放 POSIX
  文件系统即可恢复 600 生效。

## 验收

① \`docker logs dingtalk-hermes\` 里桥接服务出现 \`启动订阅 [at]\` / \`[group]\`；
② 白名单群里发 @/关键词消息，bridge.log 出现 \`处理[at]\`/\`关键词命中\` 且群里
收到回复，非白名单群静默；③ 连续两轮对话能引用上下文（history.json 增长）；
④ \`docker restart\` 后无重复回复（event_id 去重 + 回显防护）；⑤ 配了
DINGTALK_CLIENT_ID/SECRET 时私聊机器人有回复。

## 参考资料

- Hermes: https://github.com/NousResearch/hermes-agent
- DWS: https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli
EOF
}

autoExecuteFunc setEnv installDeps installDws installHermes installDingtalkBridge sanitizeHermesSeed initS6Config
