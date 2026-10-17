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
 #   2. DWS：npm i -g dingtalk-workspace-cli
 #   3. DSH：npm i -g @deepseek-ai/dsh（钉版本，默认 0.1.2-rc.1）
 #   4. 插件：dsh plugin --profile web add dingtalk-dsh-assistant（bake 进默认 DSH_HOME）
 #
 # Layer layout（数据域/登录态/技能统一在 INSTALL_PATH 下，运行期挂这一个路径；软件本体 npm 全局装在 /usr/local）：
 #   /deployment/software/dingtalk-dsh/home          # DSH_HOME：会话/轨迹/插件配置
 #   /deployment/software/dingtalk-dsh/dws-config    # DWS_CONFIG_DIR：登录态
 #   /deployment/software/dingtalk-dsh/{dws,agents}  # 技能（$HOME 软链归拢，见 relocateSkillDirs）
 #   /deployment/bin/dingtalk-dsh-start.sh           # s6 longrun 的 run body（在挂载点之外）
 #   /deployment/bin/dsh / dws                        # 启动器（软链到 npm 全局 bin）
 #
 # 构建期可覆盖（Dockerfile build-arg / 环境变量）：
 #   NPM_REGISTRY     npm 源（默认 https://registry.npmmirror.com）
 #   DWS_PIN_VERSION  DWS 版本（默认 latest）
 #   DSH_PIN_VERSION  DSH 版本（默认 0.1.2-rc.1）
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
  export DSH_PIN_VERSION="${DSH_PIN_VERSION:-0.1.2-rc.1}"

  # 数据域/登录态/技能统一收进 INSTALL_PATH 本身（不再套 data/ 子层）：
  #   home（DSH_HOME）、dws-config（登录态）、dws/agents（技能，见 relocateSkillDirs）。
  # 运行期只需挂 INSTALL_PATH 一个路径，即可持久化会话 + 登录态 + 全部技能。
  export DSH_HOME="${INSTALL_PATH}/home"
  export DWS_CONFIG_DIR="${INSTALL_PATH}/dws-config"

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
  # 推导成 /usr/local/lib/nodejs，导致 `npm i -g` 的 bin（dws/dsh/pnpm）落到
  # /usr/local/lib/nodejs/bin —— 该目录不在构建期 PATH 上，装完 `dws` 会 command not found。
  # 显式钉回 /usr/local，让 global bin 进 /usr/local/bin（与上面 node/npm/npx 软链一致）。
  npm config set prefix /usr/local || return 1

  # npm 源 + pnpm（dsh plugin add 内部依赖 pnpm 解析/安装插件包）
  npm config set registry "${NPM_REGISTRY}" || return 1
  npm install -g pnpm --registry="${NPM_REGISTRY}" || return 1
  pnpm config set registry "${NPM_REGISTRY}" 2>/dev/null || true
  echo "pnpm $(pnpm --version 2>/dev/null || echo latest) installed"
}

installDws(){
  mkdir -p /deployment/bin

  # npm 12 起默认禁用 install 脚本（postinstall 等），必须 --allow-scripts 放行，
  # 否则 dingtalk-workspace-cli 的 postinstall(node install.js) 被拦截，dws 二进制不会生成。
  local install_cmd="npm install -g dingtalk-workspace-cli --allow-scripts=dingtalk-workspace-cli --registry=${NPM_REGISTRY}"
  if [ -n "${DWS_PIN_VERSION}" ]; then
    install_cmd="npm install -g dingtalk-workspace-cli@${DWS_PIN_VERSION} --allow-scripts=dingtalk-workspace-cli --registry=${NPM_REGISTRY}"
  fi

  echo "Installing: ${install_cmd}"
  ${install_cmd} || { echo "Failed to install DWS (dingtalk-workspace-cli)" >&2; return 1; }

  # 验证安装（需求：装完 dws 后 `dws version` 能跑）
  dws version || dws --version || { echo "DWS binary missing or broken" >&2; return 1; }

  local dws_bin
  dws_bin="$(command -v dws)"
  ln -sfn "${dws_bin}" /deployment/bin/dws
  DWS_VERSION="$(dws version 2>/dev/null | head -n 1 || echo "${DWS_PIN_VERSION:-latest}")"
  export DWS_VERSION
  echo "DWS version: ${DWS_VERSION}"
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

installAssistant(){
  mkdir -p "${DSH_HOME}"
  export DSH_HOME

  # 把钉钉群接入插件装进默认 DSH_HOME 的 web profile（bake 进镜像默认数据域；
  # 运行期若用卷覆盖 DSH_HOME 为新实例，需要重新 add 一次，见 README）
  echo "Installing dingtalk-dsh-assistant into ${DSH_HOME} (profile=web)"
  dsh plugin --profile web add dingtalk-dsh-assistant || {
    echo "Failed to install dingtalk-dsh-assistant plugin" >&2
    return 1
  }
  echo "dingtalk-dsh-assistant installed into ${DSH_HOME}"
}

# 把运行用户 $HOME 钉死的技能目录归拢到 INSTALL_PATH：搬内容 → 删原目录 → 建软链（幂等）。
# DWS/DSH 把技能目录硬编码在运行用户的 $HOME（~/.dws、~/.agents），不受 DSH_HOME /
# DWS_CONFIG_DIR 控制；只有用 symlink 把这两处指进 INSTALL_PATH，单路径挂载才能覆盖技能。
# 运行用户统一为 sarmn（base 层 create_user 把其 home 定为 /deployment/accounts/sarmn），
# 故软链跟随 sarmn 的 home，不再写死 /root（root 只存在于构建期，运行期进程是 sarmn）。
relocateSkillDirs(){
  local run_user="${1:-sarmn}"
  local home_dir
  home_dir="$(getent passwd "${run_user}" | cut -d: -f6)"
  [ -n "${home_dir}" ] || home_dir="/deployment/accounts/${run_user}"

  local d src dst
  for d in dws agents; do
    src="${home_dir}/.${d}"
    dst="${INSTALL_PATH}/${d}"
    mkdir -p "${dst}"
    if [ -L "${src}" ]; then
      continue
    fi
    if [ -d "${src}" ]; then
      cp -a "${src}/." "${dst}/" 2>/dev/null || true
      rm -rf "${src}"
    fi
    ln -sfn "${dst}" "${src}"
    chown -R "${run_user}:${run_user}" "${dst}" 2>/dev/null || true
  done
}

initS6Config(){
  mkdir -p "${INSTALL_PATH}"

  # 技能目录归拢到 INSTALL_PATH（见 relocateSkillDirs）
  relocateSkillDirs sarmn

  # DSH_HOME/登录态/技能整目录收归 sarmn，保证运行期 sarmn 进程可读写（bake 时是 root 装的）
  chown -R sarmn:sarmn "${INSTALL_PATH}" 2>/dev/null || true

  # ── s6 longrun 的 run body ────────────────────────────────────────────
  # run body 以 root 启动（register_s6_longrun_cmd 不传 run_user），先在 root 态完成
  # PUID/PGID 对齐 + 属主修正 + 技能软链，再 setuidgid 切到 sarmn 前台常驻 DSH Web；
  # 重启语义交给 s6。run body 落在 /deployment/bin（挂载点 INSTALL_PATH 之外），
  # 避免整目录挂卷时被遮蔽。
  cat > /deployment/bin/dingtalk-dsh-start.sh <<EOF
#!/bin/bash
set -e

RUN_USER="sarmn"
HOME_DIR="\$(getent passwd "\${RUN_USER}" | cut -d: -f6)"
[ -n "\${HOME_DIR}" ] || HOME_DIR="/deployment/accounts/\${RUN_USER}"

# ── PUID / PGID：运行期把 sarmn 的 uid/gid 对齐到指定值（不设 = 维持 base 默认）──
# 用途：挂载卷的宿主机属主常是宿主机用户 uid（非 1000），设 PUID/PGID 即可让容器内
# sarmn 进程以相同 uid/gid 读写卷，避免权限错配。例如：
#   docker run -e PUID=\$(id -u) -e PGID=\$(id -g) ...
if [ -n "\${PUID}" ] && [ "\${PUID}" != "\$(id -u "\${RUN_USER}")" ]; then
  echo "[dingtalk-dsh] 将 \${RUN_USER} uid 调整为 \${PUID}"
  usermod -u "\${PUID}" -o "\${RUN_USER}"
fi
if [ -n "\${PGID}" ] && [ "\${PGID}" != "\$(id -g "\${RUN_USER}")" ]; then
  echo "[dingtalk-dsh] 将 \${RUN_USER} gid 调整为 \${PGID}"
  groupmod -g "\${PGID}" -o "\${RUN_USER}"
fi

mkdir -p "\${DSH_HOME}" "\${DWS_CONFIG_DIR}" "${INSTALL_PATH}/dws" "${INSTALL_PATH}/agents"

# PUID 改动后重 chown 数据域/家目录，否则 sarmn 进程写不了旧 uid 的文件
chown -R "\${RUN_USER}:\${RUN_USER}" "${INSTALL_PATH}" "\${HOME_DIR}" 2>/dev/null || true

# 技能目录软链跟随运行用户 home（幂等；home 不随 PUID 变化，始终 /deployment/accounts/sarmn）
for d in dws agents; do
  ln -sfn "${INSTALL_PATH}/\${d}" "\${HOME_DIR}/.\${d}"
done

# DWS 登录态自检：DWS_CONFIG_DIR 为空 = 尚未登录，只提醒，不阻断 DSH 起服务。
# 登录需交互（设备码），请以 sarmn 身份 exec 补做一次（保证登录态落 sarmn 名下）：
#   docker exec -it -u sarmn <container> dws auth login --device
if [ -z "\$(ls -A "\${DWS_CONFIG_DIR}" 2>/dev/null)" ]; then
  echo "[dingtalk-dsh] 未检测到 DWS 登录态（\${DWS_CONFIG_DIR} 为空）；请先执行: docker exec -it -u sarmn <container> dws auth login --device" >&2
fi

# 切到运行用户 sarmn 前台常驻 DSH Web
exec s6-setuidgid "\${RUN_USER}" dsh web --no-open
EOF
  chmod 0755 /deployment/bin/dingtalk-dsh-start.sh

  # ── 运行期环境持久化（s6 with-contenv 会注入）────────────────────────
  write_cont_env DSH_HOME "${DSH_HOME}"
  write_cont_env DWS_CONFIG_DIR "${DWS_CONFIG_DIR}"
  write_cont_env DSH_PIN_VERSION "${DSH_PIN_VERSION}"
  write_cont_env DSH_VERSION "${DSH_VERSION}"
  write_cont_env DWS_VERSION "${DWS_VERSION}"

  {
    echo "export DSH_HOME=${DSH_HOME}"
    echo "export DWS_CONFIG_DIR=${DWS_CONFIG_DIR}"
    echo "export PATH=/deployment/bin:\$PATH"
  } >> /etc/environment

  # 注册常驻服务：run body 以 root 起，内部对齐 PUID/PGID 后 setuidgid 切到 sarmn 常驻
  register_s6_longrun_cmd dingtalk-dsh "exec /bin/bash /deployment/bin/dingtalk-dsh-start.sh"

  # ── README ────────────────────────────────────────────────────────────
  cat > "${INSTALL_PATH}/README.md" <<EOF
# 钉钉数字同事（DingTalk digital colleague）

backend 软件镜像 \`software:<os_tag>-dingtalk-dsh\`，把钉钉群聊接入 DSH Agent 运行时：
@ 机器人 → 消息进 DSH 常驻会话；简单任务触发叶子会话执行；结果引用回复到群里。

## 组件

| 组件 | 作用 | 安装 |
|------|------|------|
| DWS \`dingtalk-workspace-cli\` | 钉钉工作台 CLI：登录态 + 群消息通道 | \`npm i -g\` |
| DSH \`@deepseek-ai/dsh\` | DeepSeek Harness Agent 运行时（Node ≥ 24） | \`npm i -g\`（钉版本） |
| \`dingtalk-dsh-assistant\` | DSH 插件：钉钉群聊接入常驻会话 | \`dsh plugin --profile web add\` |

## 运行

镜像 ENTRYPOINT 是 \`/init\`（s6-overlay），已注册 \`dingtalk-dsh\` longrun 服务，
启动即常驻 \`dsh web\`，进程崩溃/退出由 s6 自动拉起（无需编排层 restart）。

\`\`\`bash
docker run -d --name dingtalk-dsh \
  -v dsh_data:/deployment/software/dingtalk-dsh \
  -p 127.0.0.1:3080:3080 \
  registry.cn-hangzhou.aliyuncs.com/sarmn/software:noble-dingtalk-dsh
\`\`\`

挂载点：只需挂 \`/deployment/software/dingtalk-dsh\` 一个路径，即可持久化全部状态——
\`DSH_HOME\`（\`home\`：会话/轨迹/插件配置）、\`DWS_CONFIG_DIR\`（\`dws-config\`：登录态）、
DWS/DSH 技能（\`/deployment/accounts/sarmn/.dws\`、\`/deployment/accounts/sarmn/.agents\`
已软链到 \`dws\`、\`agents\`）。

## 运行用户与 PUID/PGID

服务统一以 \`sarmn\` 用户常驻（与 desktop 版一致）。默认 uid/gid 由 base 层
\`create_user sarmn\` 决定（通常 1000）。若挂载卷在宿主机上的属主是别的 uid/gid，
可用环境变量 \`PUID\` / \`PGID\` 让运行期把 \`sarmn\` 的 uid/gid 对齐过去，避免读写权限错配：

\`\`\`bash
docker run -d --name dingtalk-dsh \
  -e PUID=$(id -u) -e PGID=$(id -g) \
  -v dsh_data:/deployment/software/dingtalk-dsh \
  -p 127.0.0.1:3080:3080 \
  registry.cn-hangzhou.aliyuncs.com/sarmn/software:noble-dingtalk-dsh
\`\`\`

不设 \`PUID\` / \`PGID\` 时保持 base 默认（1000）。\`PUID\` / \`PGID\` 只影响 uid/gid，
不改变 \`sarmn\` 的家目录（始终 \`/deployment/accounts/sarmn\`），技能软链跟随该 home。

## 首次登录

\`\`\`bash
# 一次性：弹出设备码，用钉钉扫码/访问链接完成登录（登录态写入 DWS_CONFIG_DIR 卷）。
# 以 sarmn 身份执行，保证登录态落在运行用户名下（运行期 DSH 以 sarmn 常驻）。
docker exec -it -u sarmn dingtalk-dsh dws auth login --device
\`\`\`

## 关键配置（对应需求）

- \`DSH_HOME\`（\`home\`）：按实例隔离的数据域（每个数字同事实例独立一份；挂新卷即新实例）。
  默认镜像已把 \`dingtalk-dsh-assistant\` bake 进默认 \`home\`，挂新卷后需重跑一次
  \`docker exec -it <container> dsh plugin --profile web add dingtalk-dsh-assistant\`。
- \`DWS_CONFIG_DIR\`（\`dws-config\`）：DWS 登录态，走挂载卷持久化（容器重建不丢登录态）。
- 技能：\`/deployment/accounts/sarmn/.dws\`、\`/deployment/accounts/sarmn/.agents\`
  已软链到 \`dws\`、\`agents\`，运行期 \`dws skill install\` / \`dws skill setup\`
  新装的技能都会落进挂载路径，容器重建不丢。
- 插件权限：resident 主会话只读，leaf 任务会话拥有完整执行权限（在 DSH Web
  控制台 → Settings → Plugins → 钉钉个人助理 里配置）。
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
