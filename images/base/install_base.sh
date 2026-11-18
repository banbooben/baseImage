#!/bin/bash

load_common_sh(){
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [ -f "${script_dir}/../common.sh" ]; then
    source "${script_dir}/../common.sh"
  elif [ -f /deployment/scripts/common.sh ]; then
    source /deployment/scripts/common.sh
  else
    echo "无法加载 common.sh：未找到 ${script_dir}/../common.sh 或 /deployment/scripts/common.sh"
    exit 1
  fi
}

load_common_sh

check_target_arch(){
  ARCH=$(uname -m)

  case $ARCH in
      x86_64|amd64)
          echo "检测到: x86_64 架构"
          TARGET_ARCH="x86_64"
          ;;
      aarch64|arm64)
          echo "检测到: ARM64 架构"
          TARGET_ARCH="aarch64"
          ;;
      armv7l|armhf)
          echo "检测到: ARMv7 架构"
          TARGET_ARCH="armv7l"
          ;;
      armv6l)
          echo "检测到: ARMv6 架构"
          TARGET_ARCH="armv6l"
          ;;
      i386|i686)
          echo "检测到: x86 32位架构"
          TARGET_ARCH="i386"
          ;;
      ppc64le)
          echo "检测到: PowerPC 64位小端架构"
          TARGET_ARCH="ppc64le"
          ;;
      s390x)
          echo "检测到: IBM System z 架构"
          TARGET_ARCH="s390x"
          ;;
      *)
          echo "未知架构: $ARCH"
          exit 1
          ;;
  esac

  echo "目标架构: $TARGET_ARCH"
  export TARGET_ARCH

}

setEnv(){
  export S6_OVERLAY_VERSION=3.2.1.0
  write_cont_env S6_OVERLAY_VERSION "${S6_OVERLAY_VERSION}"
  export LANG=zh_CN.UTF-8
  export LANGUAGE=zh_CN:zh
  export LC_ALL=zh_CN.UTF-8
  check_target_arch
}


installS6(){
  mkdir -p /opt/s6-overlay
  cd /opt/s6-overlay || exit 1
  wget https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz
  tar -xf s6-overlay-noarch.tar.xz -C /


  wget https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${TARGET_ARCH}.tar.xz
  tar -xf s6-overlay-${TARGET_ARCH}.tar.xz -C /

  rm -f s6-overlay-noarch.tar.xz
  rm -f s6-overlay-${TARGET_ARCH}.tar.xz
  cd - || exit 1

}

initConfigFile(){

  mkdir -p /etc/s6-overlay/s6-rc.d/sshd/dependencies.d

  # 启动脚本
  cat > /etc/s6-overlay/s6-rc.d/sshd/run <<'EOF'
#!/bin/sh
set -e

# ensure runtime dir exists then exec sshd in foreground
mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e
EOF

  # 退出脚本
  cat > /etc/s6-overlay/s6-rc.d/sshd/finish <<'EOF'
#!/bin/sh
# Do nothing on stop
exit 0
EOF

  # 启动类型
  cat > /etc/s6-overlay/s6-rc.d/sshd/type <<'EOF'
longrun
EOF

  cat > /etc/s6-overlay/s6-rc.d/sshd/dependencies.d/base <<'EOF'

EOF

  chmod 0755 /etc/s6-overlay/s6-rc.d/sshd/run
  chmod 0755 /etc/s6-overlay/s6-rc.d/sshd/finish
  chmod 0644 /etc/s6-overlay/s6-rc.d/sshd/type
  chmod 0644 /etc/s6-overlay/s6-rc.d/sshd/dependencies.d/base

}

initFolder(){
  # 仅建目录；sudoers 必须在安装 sudo 包之后配置（见 initSudoers）
  mkdir -p /deployment/accounts/sudoers.d
  mkdir -p /deployment/software
  mkdir -p /deployment/scripts
  mkdir -p /deployment/workspace
  mkdir -p /deployment/configs
  mkdir -p /deployment/logs
  mkdir -p /deployment/data
}

initSudoers(){
  # 保留发行版自带的默认 /etc/sudoers（含 %sudo / %wheel），再用 drop-in 引入自定义目录
  #
  # 下面这层 drop-in 只有在 /etc/sudoers 引了 /etc/sudoers.d 时才生效。
  # Debian 与 RHEL 默认都有 #includedir，但不能假设——缺失时整份 drop-in 会被
  # 静默忽略，root 的 NOPASSWD 规则随之失效（表现为 sudo 索要密码）。
  if [ -f /etc/sudoers ] && \
     ! grep -qE '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
    printf '\n#includedir /etc/sudoers.d\n' >> /etc/sudoers
    echo "已为 /etc/sudoers 补上 #includedir /etc/sudoers.d"
  fi

  mkdir -p /deployment/accounts/sudoers.d
  chmod 750 /deployment/accounts/sudoers.d
  echo '@includedir /deployment/accounts/sudoers.d' > /etc/sudoers.d/00-deployment-accounts
  chmod 440 /etc/sudoers.d/00-deployment-accounts
  echo 'root ALL=(ALL) NOPASSWD:ALL' > /deployment/accounts/sudoers.d/root
  chmod 440 /deployment/accounts/sudoers.d/root
  visudo -cf /etc/sudoers >/dev/null
  visudo -cf /etc/sudoers.d/00-deployment-accounts >/dev/null
}

initSshd(){
  # ssh-keygen 不会自建父目录，缺失时直接报错退出
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  ssh-keygen -q -t rsa -b 4096 -N '' -f /root/.ssh/id_rsa
  # 不为 root 设置密码：构建期不落任何密码，root 仅允许密钥登录
  # （ubuntu base 的 root 账户本就锁密码；sshd 侧 PermitRootLogin yes 对密钥仍有效）

  # 部分发行版（如 openEuler）的 sshd_config 里没有 PermitRootLogin 行，
  # 此时 sed 静默无效果，需显式追加
  if grep -qE '^#?PermitRootLogin' /etc/ssh/sshd_config; then
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
  else
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  fi

  # 账户无密码，密码登录本就不可能成功；这里显式关掉，避免 PAM/Key 交互留下
  # 与文档（仅密钥登录）不一致的入口
  if grep -qE '^#?PasswordAuthentication' /etc/ssh/sshd_config; then
    sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
  else
    echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
  fi
  if grep -qE '^#?KbdInteractiveAuthentication' /etc/ssh/sshd_config; then
    sed -i 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
  else
    echo 'KbdInteractiveAuthentication no' >> /etc/ssh/sshd_config
  fi
}

installBase(){
  detect_distro || return 1
  echo "install base"
  # 不要 force-confold：避免保留安装前误写的残缺 /etc/sudoers（会丢掉 %sudo）
  pkg_install sudo

  # 源管理工具按发行版区分：
  # - Debian 系用 lsb-release / gnupg 加第三方源
  # - openEuler 系用 dnf-plugins-core（提供 dnf config-manager）；
  #   cpio 是 pkg_extract 解 .rpm 的依赖（rpm2cpio | cpio -idm）；
  #   p11-kit-trust 才提供 trust 命令（Debian 的 p11-kit 自带）
  # software-properties-common 不装：它会拉起 python3.12 整套 + iso-codes + systemd
  # （实测约 60-70MB），而 base 自身没有 add-apt-repository 的需求——真正需要它的
  # install_chrome.sh / install_docker.sh 各自在构建期安装并在用完后清理。
  if [ "$DISTRO_FAMILY" = "debian" ]; then
    pkg_install ca-certificates lsb-release gnupg dirmngr
  else
    pkg_install ca-certificates gnupg2 dnf-plugins-core cpio p11-kit-trust
  fi

  # 安装档位（BASE_PROFILE）：
  #   full    - 默认。带完整编译工具链，供 base / base-desktop / 现场编译场景使用
  #   runtime - 只保留运行时依赖。语言/中间件镜像的 final 阶段用它做 FROM，
  #             产物不再背 gcc、-dev 头文件和静态库（约 300MB/镜像）
  # 需要编译时请用 full 档镜像，或在 runtime 镜像里自行安装 build-essential。
  local base_packages
  if [ "${BASE_PROFILE:-full}" = "runtime" ]; then
    # xz-utils 不能省：installS6 用 tar 解 .tar.xz，缺 xz 会静默解包失败
    base_packages="
          wget curl git unzip passwd vim-tiny xz-utils
          openssh-client openssh-server p11-kit openssl
          libssl3 libsqlite3-0 libffi8 zlib1g libbz2-1.0
          liblzma5 libreadline8t64 libncursesw6 libexpat1 tk8.6
          libgdbm6t64 libgdbm-compat4t64 libdb5.3t64 libuuid1 libcrypt1 libstdc++6
          libpcre2-8-0"
  else
    # 体积取舍：
    #   - 不装 llvm：全仓库（含各 install_*.sh）没有任何 clang/llvm 使用，llvm-18 +
    #     libllvm18 实测 232MB 纯冗余；Python 的 --with-lto 用的是 gcc 的 LTO 插件。
    #   - vim 用 vim-tiny（rpm 侧映射 vim-minimal）：完整 vim 会带 vim-runtime 35.7MB，
    #     base 只需要一个可用的 vi/vim 编辑器；桌面/开发场景可按需自行安装完整版。
    base_packages="
          wget curl git unzip passwd vim-tiny
          openssh-client openssh-server p11-kit openssl
          build-essential pkg-config
          libbluetooth-dev tk-dev uuid-dev
          libssl-dev libsqlite3-dev libffi-dev
          libgdbm-dev libgdbm-compat-dev libnss3-dev libdb5.3-dev
          zlib1g-dev libbz2-dev libreadline-dev libncurses5-dev
          xz-utils libxml2-dev libxmlsec1-dev liblzma-dev libexpat1-dev"
  fi
  # shellcheck disable=SC2086
  pkg_install ${base_packages}
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin bash

  # vim-tiny（Debian）/ vim-minimal（openEuler）都只装 vi，不提供 `vim` 命令名
  # （Debian 的 alternatives 在无 /usr/bin/vim 时不会自动建；openEuler 的
  # vim-minimal 干脆只有 /usr/bin/vi）。补一个软链保证 `vim` 可用。
  if ! command -v vim >/dev/null 2>&1; then
    if [ -x /usr/bin/vim.tiny ]; then
      ln -sf /usr/bin/vim.tiny /usr/local/bin/vim
    elif command -v vi >/dev/null 2>&1; then
      ln -sf "$(command -v vi)" /usr/local/bin/vim
    fi
  fi
}

initChineseEnv(){
  detect_distro || return 1
  echo "init chinese env"
  # 只装 locale 数据；中文字体（wqy 系列，约 30MB）下沉到桌面层 install_desktop.sh：
  # 无头/语言/中间件镜像根本不需要字体，base 每瘦 1MB 都会按镜像条数放大。
  # openEuler 侧 locale 由映射表译为 glibc-all-langpacks，装完即可用。
  pkg_install locales

  case "$DISTRO_FAMILY" in
    debian)
      sed -i 's/^# *\(zh_CN.UTF-8\)/\1/' /etc/locale.gen
      locale-gen
      ;;
    rpm)
      # openEuler 通过 glibc-all-langpacks 提供语言数据（见包名映射），
      # 没有 locale.gen / locale-gen 这套两步机制，装完即可用
      ;;
  esac
}

addUser(){

  cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys || return 1
  chmod 600 /root/.ssh/authorized_keys

  # 默认业务用户；构建期不设密码，仅通过 SSH 密钥登录（--sshkey 生成密钥对并写入
  # authorized_keys）。运行期可用 -e SAM_PASSWORD=... 设置密码，届时
  # /etc/cont-init.d/15-runtime-password 会同时开启 SSH 密码登录并把 sudo
  # 切回需要密码（见 initRuntimePassword）。
  # 无密码账户无法通过 sudo 的密码校验，故 bake 时用 --nopasswd：否则 sam 虽在
  # sudo 组却永远 sudo 不了（报 "a password is required"）。
  # 必须把失败抛出去：否则用户没建成也照样往下走，
  # 最后打出一个没有 sam 的镜像，问题要等到运行时才暴露
  create_user sam --sudo --nopasswd --sshkey || return 1

}

# PUID/PGID 全局对齐：cont-init.d 在**所有** s6-rc 服务启动之前执行一次。
# 之后启动的服务（vnc/desktop/clash-verge/redis/dingtalk-hermes …）用 s6-setuidgid
# sam 时按名字查 /etc/passwd，查到的就是这里改过的新 uid/gid —— 各服务零改动生效。
#
# 注意 shebang 必须用 #!/command/with-contenv bash（与 register_s6_longrun_cmd 一致）：
# s6-overlay v3 里 cont-init.d 脚本经 s6rc-oneshot-runner 以**纯净环境**执行，
# 普通 #!/bin/bash 下既看不到容器 -e 变量也看不到 cont-env.d，PUID/PGID 恒为空、
# 脚本走快速路径静默跳过（实测确认）；with-contenv 从 /run/s6/container_environment
# 载入完整容器环境后才能读到 PUID/PGID。
initPuidPgid(){

  mkdir -p /etc/cont-init.d
  cat > /etc/cont-init.d/05-puid-pgid << 'EOF'
#!/command/with-contenv bash
# PUID / PGID：容器启动时把 sam 的 uid/gid 对齐到指定值（不设 = 维持 bake 默认）。
# 用途：挂载卷的宿主机属主常是宿主机用户 uid（非 1000），对齐后容器内 sam 进程
# 以相同 uid/gid 读写卷，避免权限错配。例如：
#   docker run -e PUID=$(id -u) -e PGID=$(id -g) ...
RUN_USER="sam"

# 两个都未设置：快速路径直接退出（默认行为与未提供该特性时完全一致）
[ -n "${PUID}${PGID}" ] || exit 0

# 非法输入只告警跳过，不让一个写错的 env 把容器 init 打挂
case "${PUID}" in ''|*[!0-9]*) [ -z "${PUID}" ] || { echo "[puid-pgid] PUID 非数字，忽略: '${PUID}'" >&2; PUID=""; };; esac
case "${PGID}" in ''|*[!0-9]*) [ -z "${PGID}" ] || { echo "[puid-pgid] PGID 非数字，忽略: '${PGID}'" >&2; PGID=""; };; esac
[ -n "${PUID}${PGID}" ] || exit 0

id "${RUN_USER}" >/dev/null 2>&1 || exit 0
cur_uid="$(id -u "${RUN_USER}")"
cur_gid="$(id -g "${RUN_USER}")"
changed=0

if [ -n "${PGID}" ] && [ "${PGID}" != "${cur_gid}" ]; then
  echo "[puid-pgid] ${RUN_USER} gid: ${cur_gid} -> ${PGID}"
  groupmod -g "${PGID}" -o "${RUN_USER}"
  changed=1
fi
if [ -n "${PUID}" ] && [ "${PUID}" != "${cur_uid}" ]; then
  echo "[puid-pgid] ${RUN_USER} uid: ${cur_uid} -> ${PUID}"
  usermod -u "${PUID}" -o "${RUN_USER}"
  changed=1
fi

# 只有 uid/gid 真的变了才 chown home：bake 进去的文件属主还是旧 uid，不重 chown
# 新 sam 读写不了。没变（带相同 PUID 重启）则跳过，避免每次启动全量扫 home。
# 注意 cont-init.d 按文件名序执行：本脚本 05 先于 desktop 的 10-fix-sam-home，
# 后者会再无条件 chown 一次 home（既有行为，幂等）。
if [ "${changed}" = "1" ]; then
  chown -R "${RUN_USER}:${RUN_USER}" "/deployment/accounts/${RUN_USER}" 2>/dev/null || true
fi
EOF
  chmod 0755 /etc/cont-init.d/05-puid-pgid

}

# 运行期账户密码：镜像里仍然不写任何密码，但容器启动时可以用环境变量注入。
# 为什么放运行期而不是构建期：构建期 secret 只是不进构建日志，密码最终仍要写进
# /etc/shadow（或 redis.conf / vnc passwd），随镜像层被 pull/save 取出，而且所有
# 部署实例共用同一个密码、改密码必须重建镜像。运行期注入按实例生效，重启即可换。
#
# 约定：SAM_PASSWORD 是 sam 账户密码的唯一来源。
#   - 非空：设置密码，并开启 SSH 密码登录、把 sudo 切回“需要密码”（与旧逻辑一致）
#   - 空：账户保持锁定，SSH 仅密钥，sudo 免密（镜像默认行为）
# 同一容器先带密码启动、之后去掉该变量重启时，也会被重新锁回去。
initRuntimePassword(){

  mkdir -p /etc/cont-init.d
  cat > /etc/cont-init.d/15-runtime-password << 'EOF'
#!/command/with-contenv bash
# with-contenv 必需：cont-init.d 经 s6rc-oneshot-runner 以纯净环境执行，
# 普通 #!/bin/bash 读不到容器 -e 变量（同 05-puid-pgid）。
RUN_USER="sam"
SUDOERS_FILE="/deployment/accounts/sudoers.d/${RUN_USER}"

write_sudoers(){
  # sudoers.d 可能被挂载为只读；写不进去只告警，不让容器起不来
  if ! printf '%s\n' "$1" > "${SUDOERS_FILE}" 2>/dev/null; then
    echo "[password] 无法写入 ${SUDOERS_FILE}（可能只读挂载），sudo 策略未更新" >&2
    return 0
  fi
  chmod 440 "${SUDOERS_FILE}" 2>/dev/null || true
  visudo -cf "${SUDOERS_FILE}" >/dev/null 2>&1 || {
    echo "[password] ${SUDOERS_FILE} 语法校验失败" >&2
    return 1
  }
}

set_ssh_password_auth(){
  # 镜像未装 sshd 时静默跳过
  [ -f /etc/ssh/sshd_config ] || return 0
  # sshd 取“第一个出现的值”，主配置改了就生效；缺失该行时追加
  if grep -qE '^#?PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null; then
    sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication $1/" /etc/ssh/sshd_config
  else
    echo "PasswordAuthentication $1" >> /etc/ssh/sshd_config
  fi
}

if [ -n "${SAM_PASSWORD}" ]; then
  # chpasswd 的 user:password 只按第一个冒号切分，密码含冒号也没问题
  if ! printf '%s:%s\n' "${RUN_USER}" "${SAM_PASSWORD}" | chpasswd; then
    echo "[password] 设置 ${RUN_USER} 密码失败" >&2
    exit 1
  fi
  echo "[password] 已根据 SAM_PASSWORD 为 ${RUN_USER} 设置密码"

  # 给了密码就让密码登录可用，否则该密码只能用于 su / 本地控制台
  set_ssh_password_auth yes

  # 有密码的账户按常规方式 sudo（提示输入密码），与旧的构建期逻辑一致
  write_sudoers "${RUN_USER} ALL=(ALL:ALL) ALL" || exit 1
else
  # 确保账户保持锁定：新建容器本来就是锁定态；这里覆盖“带密码启动过、
  # 之后去掉变量重启”的情况
  case "$(passwd -S "${RUN_USER}" 2>/dev/null | awk '{print $2}')" in
    L|LK) : ;;
    *) passwd -l "${RUN_USER}" >/dev/null 2>&1 || true ;;
  esac

  set_ssh_password_auth no

  write_sudoers "${RUN_USER} ALL=(ALL) NOPASSWD:ALL" || exit 1
fi
EOF
  chmod 0755 /etc/cont-init.d/15-runtime-password
}

autoExecuteFunc setEnv initFolder installBase initSudoers installS6 initSshd addUser initChineseEnv initConfigFile initPuidPgid initRuntimePassword

# 兜底断言：autoExecuteFunc 在某个步骤重试 5 次后仍失败时只告警不中断，
# 曾导致 runtime 档缺 xz-utils → s6 解包失败 → 产物没有 /init 却构建成功。
# 入口缺失的镜像根本无法启动，必须在构建期就失败。
[ -x /init ] || { echo "错误：s6-overlay 未正确安装（/init 缺失），构建产物不可用" >&2; exit 1; }
