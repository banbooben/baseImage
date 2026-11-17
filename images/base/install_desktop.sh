#!/bin/bash
source /deployment/scripts/common.sh

setEnv() {
  # 设置环境变量
  export PATH="/deployment/software/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export DEBIAN_FRONTEND=noninteractive
  export DISPLAY=:1
}

installDesktop() {
  detect_distro || return 1
  echo "Installing RDP server..."

  pkg_update
  pkg_install \
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
      fonts-wqy-zenhei fonts-wqy-microhei \
      python3-numpy

  # build-essential 等工具链 base 已提供；llvm 已从 base 移除且此处同样无使用方
  pkg_install build-essential libssl-dev zlib1g-dev libbz2-dev \
          libreadline-dev libsqlite3-dev wget curl libncurses5-dev \
          xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
  # 镜像内不写 VNC 密码：运行前由使用者提供 ~/.vnc/passwd（见 vnc/start.sh 的检查）
  mkdir -p /deployment/accounts/sam/.vnc
  # 剪贴板与输入法的守护进程按发行版区分：
  #   Debian   autocutsel 做 PRIMARY/CLIPBOARD 互通；fcitx5 带 GTK/Qt 模块
  #   openEuler 无 autocutsel（改用 xfce4-clipman，已在 xfce4-goodies 内）；
  #             只有 fcitx4 且无 GTK immodule，GTK/Qt 都退回 XIM
  local clipboard_daemons im_env fcitx_daemon
  if [ "$DISTRO_FAMILY" = "debian" ]; then
    clipboard_daemons='autocutsel -fork
autocutsel -selection PRIMARY -fork'
    im_env='export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx'
    fcitx_daemon='fcitx5 -d 2>/dev/null || true'
  else
    clipboard_daemons='# 剪贴板同步由 xfce4-clipman（面板插件）负责'
    im_env='export GTK_IM_MODULE=xim
export QT_IM_MODULE=xim'
    fcitx_daemon='fcitx -d 2>/dev/null || true'
  fi

  # vncconfig：VNC 协议剪贴板 <-> X11
  {
  cat << 'XSTARTUP_HEAD'
#!/bin/sh
unset SESSION_MANAGER
vncconfig -nowin &
XSTARTUP_HEAD
  printf '%s\n' "$clipboard_daemons"
  cat << 'XSTARTUP_BODY'

# ── D-Bus session bus ────────────────────────────────────────
# 显式启动 dbus-daemon 并保存地址，供 s6 服务（如 clash-verge）读取
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  eval "$(dbus-launch --sh-syntax --exit-with-session)"
fi
echo "${DBUS_SESSION_BUS_ADDRESS}" > /tmp/.dbus-session-address
chmod 644 /tmp/.dbus-session-address

# ── 输入法环境变量 ──────────────────────────────────────────
XSTARTUP_BODY
  printf '%s\n' "$im_env"
  cat << 'XSTARTUP_TAIL'
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx

# ── 导入容器环境变量到桌面会话 ──────────────────────────────
# VNC xstartup 不走 PAM，GUI 应用不会自动读取容器 ENV。
# VNC start.sh 已将 PID 1 环境 dump 到 /tmp/container-env
if [ -r /tmp/container-env ]; then
  while IFS='=' read -r k v; do
    [ -n "${k}" ] && export "${k}=${v}"
  done < /tmp/container-env
fi

# 启动输入法守护进程
XSTARTUP_TAIL
  printf '%s\n' "$fcitx_daemon"
  printf '\nexec startxfce4\n'
  } > /deployment/accounts/sam/.vnc/xstartup

  chmod +x /deployment/accounts/sam/.vnc/xstartup

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
  # 保证登录环境带上 DISPLAY；.vnc 必须属 sam（passwd 600，否则 VNC 起不来）
  su - sam -c 'env > /deployment/accounts/sam/.env'
  grep -q '^DISPLAY=' /deployment/accounts/sam/.env \
    || echo 'DISPLAY=:1' >> /deployment/accounts/sam/.env
  write_cont_env DISPLAY ":1"
  chown -R sam:sam /deployment/accounts/sam

  echo "RDP server installed and configured."
}

initVncConfig(){

  # 初始化目录
  mkdir -p /etc/s6-overlay/s6-rc.d/vnc/dependencies.d

  # cont-init：以 root 修正 home 属主（VNC 需要 sam 拥有 ~/.vnc/passwd 等文件）
  # s6-overlay v3 的 oneshot up 由 execlineb 解析，不能用 bash，所以 chown 放这里
  mkdir -p /etc/cont-init.d
  cat > /etc/cont-init.d/10-fix-sam-home << 'EOF'
#!/bin/bash
chown -R sam:sam /deployment/accounts/sam 2>/dev/null || true
EOF
  chmod 0755 /etc/cont-init.d/10-fix-sam-home

  # 启动类型
  cat > /etc/s6-overlay/s6-rc.d/vnc/type <<'EOF'
oneshot
EOF

  # 启动：降权给 sam 起 VNC（execline 语法，#!/bin/bash 视为注释）
  cat > /etc/s6-overlay/s6-rc.d/vnc/up << 'EOF'
#!/bin/bash
exec s6-setuidgid sam /etc/s6-overlay/s6-rc.d/vnc/start.sh
EOF

  # VNC 相关配置
  cat > /etc/s6-overlay/s6-rc.d/vnc/start.sh <<'EOF'
#!/bin/bash
set -e
export HOME=/deployment/accounts/sam
export USER=sam
export DISPLAY=:1
RESOLUTION=${RESOLUTION:-1920x1080}
# 镜像不内置 VNC 密码；缺少密码文件时 tigervnc 会在非交互环境里挂住或失败，
# 这里直接给出可操作的错误。生成方式（在宿主机挂载的 home 目录里执行）：
#   printf '你的密码' | vncpasswd -f > /deployment/accounts/sam/.vnc/passwd
#   chmod 600 /deployment/accounts/sam/.vnc/passwd
if [ ! -s "${HOME}/.vnc/passwd" ]; then
  echo "[vnc] 缺少 ${HOME}/.vnc/passwd：请先提供 VNC 密码文件再重启容器" >&2
  exit 1
fi
# 导出容器环境变量供桌面会话导入（xstartup 不走 PAM）
cat /proc/1/environ | tr '\0' '\n' > /tmp/container-env
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

exec s6-setuidgid sam /etc/s6-overlay/s6-rc.d/desktop/start.sh -e

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
  detect_distro || return 1
  local cfg_root="/deployment/accounts/sam/.config"

  if [ "$DISTRO_FAMILY" = "debian" ]; then
    # ── fcitx5 默认配置：英文键盘 + 中文拼音，Ctrl+Space 切换 ──
    local fcitx5_conf="${cfg_root}/fcitx5"
    # 注意：profile 是「文件」（下面 heredoc 写入），不是目录——mkdir 只建 conf/。
    # 若误把 profile 建成目录，cat > 会因 Is a directory 静默失败，拼音配置丢失。
    mkdir -p "${fcitx5_conf}/conf"

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
  else
    # ── fcitx4 默认配置 ──
    # openEuler 只有 fcitx 4.2.9，配置文件格式与 fcitx5 完全不同：
    #   profile  输入法列表（EnabledIMList 的每项形如 name:True）
    #   config   全局开关，TriggerKey 默认即为 Ctrl+Space，此处显式写明
    local fcitx4_conf="${cfg_root}/fcitx"
    mkdir -p "${fcitx4_conf}/conf"

    cat > "${fcitx4_conf}/profile" <<'FCITX4_PROFILE'
[Profile]
EnabledIMList=pinyin:True,keyboard-us:True,
DefaultIM=pinyin
FCITX4_PROFILE

    cat > "${fcitx4_conf}/config" <<'FCITX4_CONFIG'
[Hotkey]
TriggerKey=CTRL_SPACE
FCITX4_CONFIG

    # 经典界面：竖排候选、字号（无 fcitx5 的 PerScreenDPI，交由 Xft 默认 DPI）
    cat > "${fcitx4_conf}/conf/fcitx-classic-ui.config" <<'FCITX4_UI'
[ClassicUI]
VerticalCandidateList=False
Font="Sans Serif 11"
MenuFont="Sans Serif 11"
TrayFont="Sans Serif 11"
FCITX4_UI
  fi

  chown -R sam:sam "${cfg_root}"
  echo "input method configured (pinyin, Ctrl+Space toggle)"
}

autoExecuteFunc setEnv installDesktop initVncConfig initDesktopConfig initInputMethodConfig
