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

  # # 配置 supervisor 监控 /deployment/supervisor.d 文件夹
  # echo "[unix_http_server]
  # [unix_http_server]
  # file=/var/run/supervisor.sock
  # chmod=0700

  # [supervisord]
  # logfile=/deployment/logs/supervisor/supervisord.log ; 主日志文件路径
  # logfile_maxbytes=50MB                      ; 日志文件最大大小
  # logfile_backups=10                         ; 日志文件备份数量
  # loglevel=info                              ; 日志级别 (可选: critical, error, warn, info, debug, trace)
  # pidfile=/deployment/software/supervisor/supervisor.pid           ; PID 文件路径
  # nodaemon=true                              ; 是否以守护进程方式运行
  # minfds=1024                                ; 最小文件描述符限制
  # minprocs=200                               ; 最小进程数限制

  # [rpcinterface:supervisor]
  # supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

  # [supervisorctl]
  # serverurl=unix:///deployment/software/supervisor/supervisor.sock

  # [include]
  # files = /deployment/software/supervisor/supervisor.d/*.conf
  # " > /deployment/software/supervisor/supervisord.conf

  #   echo "
  # [supervisord]
  # nodaemon=true

  # [program:sshd]
  # command=sleep 1
  # command = /bin/bash -c 'mkdir -p /run/sshd && /usr/sbin/sshd -D'
  # autorestart = true
  # autostart = true
  # stderr_logfile = /deployment/logs/supervisor/sshd.err
  # stdout_logfile = /deployment/logs/supervisor/sshd.log
  # " > /deployment/software/sshd/sshd.conf

  # echo "supervisord -c /deployment/software/supervisor/supervisord.conf" > /deployment/software/supervisor/start.sh
  # chmod +x /deployment/software/supervisor/start.sh

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

  echo "@includedir /deployment/accounts/sudoers.d" >> /etc/sudoers
  echo 'root ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
  # 基础目录
  mkdir -p /deployment/accounts/sudoers.d
  mkdir -p /deployment/software
  mkdir -p /deployment/scripts
  mkdir -p /deployment/workspace
  mkdir -p /deployment/configs
  mkdir -p /deployment/logs
  mkdir -p /deployment/data

  # sshd 相关目录
  mkdir -p /deployment/software
}

initSshd(){
  ssh-keygen -q -t rsa -b 4096 -N '' -f /root/.ssh/id_rsa
  ensure_password ROOT_PASSWORD
  echo "root:${ROOT_PASSWORD}" | chpasswd
  unset ROOT_PASSWORD
  sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
}

installBase(){
  echo "install base"
  apt install -y --no-install-recommends sudo -o Dpkg::Options::="--force-confold"
  apt install -y --no-install-recommends ca-certificates lsb-release software-properties-common gnupg dirmngr
  apt install -y --no-install-recommends \
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
  echo "init chinese env"
  apt-get install -y --no-install-recommends \
      fonts-wqy-zenhei \
      fonts-wqy-microhei \
      ttf-wqy-zenhei \
      ttf-wqy-microhei \
      locales
  sed -i 's/^# *\(zh_CN.UTF-8\)/\1/' /etc/locale.gen
  locale-gen

}

addUser(){

  cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys

  # 默认业务用户；密码通过 SARMN_PASSWORD（--build-arg / CI 变量）指定，未设则随机生成
  ensure_password SARMN_PASSWORD
  create_user sarmn "${SARMN_PASSWORD}" --sudo --sshkey
  unset SARMN_PASSWORD

  create_user share               --sudo --sshkey
  create_user hadoop              --sudo --sshkey
  create_user mysql               --sudo --sshkey

}


autoExecuteFunc setEnv initFolder installBase installS6 initSshd addUser initChineseEnv initConfigFile
