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
      autocutsel \
      openssl \
      websockify \
      xorg \
      xdg-utils \
      xfce4 xfce4-goodies dbus-x11 \
      fcitx5 fcitx5-chinese-addons \
      fcitx5-frontend-gtk3 fcitx5-frontend-gtk2 fcitx5-frontend-qt5 \
      fcitx5-module-cloudpinyin \
      python3-numpy

  apt-get install -y --no-install-recommends build-essential libssl-dev zlib1g-dev libbz2-dev \
          libreadline-dev libsqlite3-dev wget curl llvm libncurses5-dev \
          xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
  mkdir -p /deployment/accounts/sarmn/.vnc
  ensure_password VNC_PASSWORD
  echo "${VNC_PASSWORD}" | vncpasswd -f > /deployment/accounts/sarmn/.vnc/passwd
  unset VNC_PASSWORD
  chmod 600 /deployment/accounts/sarmn/.vnc/passwd
  # vncconfig：VNC 协议剪贴板 <-> X11；autocutsel：PRIMARY/CLIPBOARD 互通（终端选中复制）
  cat > /deployment/accounts/sarmn/.vnc/xstartup << 'XSTARTUP'
#!/bin/sh
unset SESSION_MANAGER
vncconfig -nowin &
autocutsel -fork
autocutsel -selection PRIMARY -fork

# ── D-Bus session bus ────────────────────────────────────────
# 显式启动 dbus-daemon 并保存地址，供 s6 服务（如 clash-verge）读取
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  eval "$(dbus-launch --sh-syntax --exit-with-session)"
fi
echo "${DBUS_SESSION_BUS_ADDRESS}" > /tmp/.dbus-session-address
chmod 644 /tmp/.dbus-session-address

# ── 输入法环境变量 ──────────────────────────────────────────
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx

# 启动 fcitx5 输入法守护进程
fcitx5 -d --verbose 2>/dev/null || true

exec startxfce4
XSTARTUP

  chmod +x /deployment/accounts/sarmn/.vnc/xstartup

  git clone https://github.com/novnc/noVNC.git /deployment/software/noVNC

  git clone https://github.com/novnc/websockify /deployment/software/noVNC/utils/websockify

  # 自定义首页：跳转到 vnc.html 并开启自适应缩放
  cat > /deployment/software/noVNC/index.html << 'NOVNC_INDEX'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Desktop</title>
  <meta http-equiv="refresh" content="0;url=vnc.html?resize=scale&autoconnect=true">
  <style>
    body { background:#1e1e1e; color:#ccc; text-align:center;
           padding-top:40vh; font-family:system-ui,sans-serif; }
    a { color:#7ecfff; }
  </style>
</head>
<body>
  <p>Loading desktop&hellip;</p>
  <p><small><a href="vnc.html">Open without scaling</a></small></p>
</body>
</html>
NOVNC_INDEX
  # 保证登录环境带上 DISPLAY；.vnc 必须属 sarmn（passwd 600，否则 VNC 起不来）
  su - sarmn -c 'env > /deployment/accounts/sarmn/.env'
  grep -q '^DISPLAY=' /deployment/accounts/sarmn/.env \
    || echo 'DISPLAY=:1' >> /deployment/accounts/sarmn/.env
  write_cont_env DISPLAY ":1"
  chown -R sarmn:sarmn /deployment/accounts/sarmn

  echo "RDP server installed and configured."
}

initVncConfig(){

  # 初始化目录
  mkdir -p /etc/s6-overlay/s6-rc.d/vnc/dependencies.d

  # cont-init：以 root 修正 home 属主（VNC 需要 sarmn 拥有 ~/.vnc/passwd 等文件）
  # s6-overlay v3 的 oneshot up 由 execlineb 解析，不能用 bash，所以 chown 放这里
  mkdir -p /etc/cont-init.d
  cat > /etc/cont-init.d/10-fix-sarmn-home << 'EOF'
#!/bin/bash
chown -R sarmn:sarmn /deployment/accounts/sarmn 2>/dev/null || true
EOF
  chmod 0755 /etc/cont-init.d/10-fix-sarmn-home

  # 启动类型
  cat > /etc/s6-overlay/s6-rc.d/vnc/type <<'EOF'
oneshot
EOF

  # 启动：降权给 sarmn 起 VNC（execline 语法，#!/bin/bash 视为注释）
  cat > /etc/s6-overlay/s6-rc.d/vnc/up << 'EOF'
#!/bin/bash
exec s6-setuidgid sarmn /etc/s6-overlay/s6-rc.d/vnc/start.sh
EOF

  # VNC 相关配置
  cat > /etc/s6-overlay/s6-rc.d/vnc/start.sh <<'EOF'
#!/bin/bash
set -e
export HOME=/deployment/accounts/sarmn
export USER=sarmn
export DISPLAY=:1
RESOLUTION=${RESOLUTION:-1920x1080}
vncserver :1 -geometry "$RESOLUTION" -depth 24
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


initInputMethodConfig(){
  # ── fcitx5 默认配置：英文键盘 + 中文拼音，Ctrl+Space 切换 ──
  local fcitx5_conf="/deployment/accounts/sarmn/.config/fcitx5"
  mkdir -p "${fcitx5_conf}/conf" "${fcitx5_conf}/profile"

  # profile：输入法列表（keyboard-us + pinyin）
  cat > "${fcitx5_conf}/profile" <<'FCITX5_PROFILE'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=Default

[Profile]
EnabledIMList=pinyin,keyboard-us
FCITX5_PROFILE

  # 候选项数 & 云拼音（可选，依赖 fcitx5-module-cloudpinyin）
  cat > "${fcitx5_conf}/conf/classicui.conf" <<'FCITX5_UI'
Vertical Candidate List=False
PerScreenDPI=True
Font="Sans Serif 11"
MenuFont="Sans Serif 11"
TrayFont="Sans Serif 11"
FCITX5_UI

  chown -R sarmn:sarmn "/deployment/accounts/sarmn/.config"
  echo "fcitx5 input method configured (pinyin, Ctrl+Space toggle)"
}

source /deployment/scripts/common.sh
autoExecuteFunc setEnv installDesktop initVncConfig initDesktopConfig initInputMethodConfig



















