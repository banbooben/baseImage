#!/bin/bash

setEnv() {
  # 设置环境变量
  export PATH="/deployment/software/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export DEBIAN_FRONTEND=noninteractive
  export DISPLAY=:1
}

installDesktop() {
  echo "Installing RDP server..."

  # 安装 xrdp
  apt-get update
  apt-get install --no-install-recommends -y \
      tightvncserver \
      tigervnc-standalone-server \
      tigervnc-common \
      openssl \
      websockify \
      xorg \
      xdg-utils \
      xfce4 xfce4-goodies dbus-x11 \
      python3-numpy

  apt-get install -y --no-install-recommends build-essential libssl-dev zlib1g-dev libbz2-dev \
          libreadline-dev libsqlite3-dev wget curl llvm libncurses5-dev \
          xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
  mkdir -p /deployment/accounts/sarmn/.vnc
  ensure_password VNC_PASSWORD
  echo "${VNC_PASSWORD}" | vncpasswd -f > /deployment/accounts/sarmn/.vnc/passwd
  unset VNC_PASSWORD
  chmod 600 /deployment/accounts/sarmn/.vnc/passwd
  cat > /deployment/accounts/sarmn/.vnc/xstartup << 'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF

  chmod +x /deployment/accounts/sarmn/.vnc/xstartup

  git clone https://github.com/novnc/noVNC.git /deployment/software/noVNC

  git clone https://github.com/novnc/websockify /deployment/software/noVNC/utils/websockify

  ln -s /deployment/software/noVNC/vnc.html /deployment/software/noVNC/index.html
  su - sarmn -c 'env > /deployment/accounts/sarmn/.env'

  echo "RDP server installed and configured."
}

initVncConfig(){

  # 初始化目录
  mkdir -p /etc/s6-overlay/s6-rc.d/vnc/dependencies.d

  # 启动类型
  cat > /etc/s6-overlay/s6-rc.d/vnc/type <<'EOF'
oneshot
EOF

  # 启动
  cat > /etc/s6-overlay/s6-rc.d/vnc/up << 'EOF'
#!/bin/bash
exec s6-setuidgid sarmn /etc/s6-overlay/s6-rc.d/vnc/start.sh
EOF

  # VNC 相关配置
  cat > /etc/s6-overlay/s6-rc.d/vnc/start.sh <<'EOF'
#!/bin/bash

echo "设置环境变量"
export $(xargs <  /deployment/accounts/sarmn/.env)

echo "淇敼鏉冮檺"
sudo chown -R sarmn:sarmn /deployment/accounts/sarmn/

# 设置分辨率
RESOLUTION=${RESOLUTION:-1920x1080}
xhost +local:

vncserver :1 -geometry $RESOLUTION -depth 24
EOF

  # 停止脚本
  cat > /etc/s6-overlay/s6-rc.d/vnc/down << 'EOF'
#!/bin/bash

ps -ef | grep vnc | awk '{print $2}' | xargs -I {} kill -9 {}
ps -ef | grep dbus-launch | awk '{print $2}' | xargs -I {} kill -9 {}

EOF

# 依赖
cat > /etc/s6-overlay/s6-rc.d/vnc/dependencies.d/base <<'EOF'
EOF

# 启动 VNC
cat > /etc/s6-overlay/s6-rc.d/user/contents.d/vnc <<'EOF'
EOF

  chmod 0755 /etc/s6-overlay/s6-rc.d/vnc/up
  chmod 0755 /etc/s6-overlay/s6-rc.d/vnc/down
  chmod 0755 /etc/s6-overlay/s6-rc.d/vnc/start.sh
  chmod 0644 /etc/s6-overlay/s6-rc.d/vnc/type
  chmod 0644 /etc/s6-overlay/s6-rc.d/vnc/dependencies.d/base

}

initDesktopConfig(){

  mkdir -p /etc/s6-overlay/s6-rc.d/desktop/dependencies.d
  # noVNC 相关配置


  # 启动类型
  cat > /etc/s6-overlay/s6-rc.d/desktop/type <<'EOF'
longrun
EOF

  # 启动命令
  cat > /etc/s6-overlay/s6-rc.d/desktop/run << 'EOF'
#!/bin/bash

exec s6-setuidgid sarmn /etc/s6-overlay/s6-rc.d/desktop/start.sh -e

EOF


  # 启动命令
  cat > /etc/s6-overlay/s6-rc.d/desktop/start.sh << 'EOF'
#!/bin/bash

/usr/bin/websockify --web /deployment/software/noVNC 6080 localhost:5901

EOF

  # 停止脚本
  cat > /etc/s6-overlay/s6-rc.d/desktop/finish << 'EOF'
#!/bin/bash

ps -ef | grep ssh-agent | awk '{print $2}' | xargs -I {} kill -9 {}
ps -ef | grep websockify | awk '{print $2}' | xargs -I {} kill -9 {}

EOF

  # 依赖
  cat > /etc/s6-overlay/s6-rc.d/desktop/dependencies.d/vnc <<'EOF'
EOF

  # 启动 desktop
  cat > /etc/s6-overlay/s6-rc.d/user/contents.d/desktop <<'EOF'
EOF

  chmod 0755 /etc/s6-overlay/s6-rc.d/desktop/run
  chmod 0755 /etc/s6-overlay/s6-rc.d/desktop/finish
  chmod 0755 /etc/s6-overlay/s6-rc.d/desktop/start.sh
  chmod 0644 /etc/s6-overlay/s6-rc.d/desktop/type
  chmod 0644 /etc/s6-overlay/s6-rc.d/desktop/dependencies.d/vnc

}


source /deployment/scripts/common.sh
autoExecuteFunc setEnv installDesktop initVncConfig initDesktopConfig



















