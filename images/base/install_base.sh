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
  ensure_password ROOT_PASSWORD
  echo "root:${ROOT_PASSWORD}" | chpasswd
  unset ROOT_PASSWORD

  # 部分发行版（如 openEuler）的 sshd_config 里没有 PermitRootLogin 行，
  # 此时 sed 静默无效果，需显式追加
  if grep -qE '^#?PermitRootLogin' /etc/ssh/sshd_config; then
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
  else
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  fi
}

installBase(){
  detect_distro || return 1
  echo "install base"
  # 不要 force-confold：避免保留安装前误写的残缺 /etc/sudoers（会丢掉 %sudo）
  pkg_install sudo

  # 源管理工具按发行版区分：
  # - Debian 系用 lsb-release / software-properties-common 加第三方源
  # - openEuler 系用 dnf-plugins-core（提供 dnf config-manager）；
  #   cpio 是 pkg_extract 解 .rpm 的依赖（rpm2cpio | cpio -idm）；
  #   p11-kit-trust 才提供 trust 命令（Debian 的 p11-kit 自带）
  if [ "$DISTRO_FAMILY" = "debian" ]; then
    pkg_install ca-certificates lsb-release software-properties-common gnupg dirmngr
  else
    pkg_install ca-certificates gnupg2 dnf-plugins-core cpio p11-kit-trust
  fi

  pkg_install \
          wget curl git unzip passwd vim \
          openssh-client openssh-server p11-kit openssl \
          build-essential pkg-config llvm \
          libbluetooth-dev tk-dev uuid-dev \
          libssl-dev libsqlite3-dev libffi-dev \
          libgdbm-dev libgdbm-compat-dev libnss3-dev libdb5.3-dev \
          zlib1g-dev libbz2-dev libreadline-dev libncurses5-dev \
          xz-utils libxml2-dev libxmlsec1-dev liblzma-dev libexpat1-dev
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin bash
}

initChineseEnv(){
  detect_distro || return 1
  echo "init chinese env"
  # openEuler 侧由映射表译为 wqy-zenhei-fonts / wqy-microhei-fonts
  # （这两个包在 openEuler 的 OS 源内，无需 EPOL）
  pkg_install \
      fonts-wqy-zenhei \
      fonts-wqy-microhei \
      ttf-wqy-zenhei \
      ttf-wqy-microhei \
      locales

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

  # 默认业务用户；密码通过 SARMN_PASSWORD（--build-arg / CI 变量）指定，未设则随机生成
  ensure_password SARMN_PASSWORD
  # 必须把失败抛出去：否则用户没建成也照样往下走，
  # 最后打出一个没有 sarmn 的镜像，问题要等到运行时才暴露
  create_user sarmn "${SARMN_PASSWORD}" --sudo --sshkey || return 1
  unset SARMN_PASSWORD

}

# PUID/PGID 全局对齐：cont-init.d 在**所有** s6-rc 服务启动之前执行一次。
# 之后启动的服务（vnc/desktop/clash-verge/redis/dingtalk-dsh …）用 s6-setuidgid
# sarmn 时按名字查 /etc/passwd，查到的就是这里改过的新 uid/gid —— 各服务零改动生效。
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
# PUID / PGID：容器启动时把 sarmn 的 uid/gid 对齐到指定值（不设 = 维持 bake 默认）。
# 用途：挂载卷的宿主机属主常是宿主机用户 uid（非 1000），对齐后容器内 sarmn 进程
# 以相同 uid/gid 读写卷，避免权限错配。例如：
#   docker run -e PUID=$(id -u) -e PGID=$(id -g) ...
RUN_USER="sarmn"

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
# 新 sarmn 读写不了。没变（带相同 PUID 重启）则跳过，避免每次启动全量扫 home。
# 注意 cont-init.d 按文件名序执行：本脚本 05 先于 desktop 的 10-fix-sarmn-home，
# 后者会再无条件 chown 一次 home（既有行为，幂等）。
if [ "${changed}" = "1" ]; then
  chown -R "${RUN_USER}:${RUN_USER}" "/deployment/accounts/${RUN_USER}" 2>/dev/null || true
fi
EOF
  chmod 0755 /etc/cont-init.d/05-puid-pgid

}

autoExecuteFunc setEnv initFolder installBase initSudoers installS6 initSshd addUser initChineseEnv initConfigFile initPuidPgid
