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
  # 镜像里不落密码文件：运行期由 15-vnc-password 用 VNC_PASSWORD 生成
  # （未设置时用默认密码），也可挂载 ~/.vnc/passwd（挂载文件优先）
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
# cont-init 15-vnc-password 以 root 将容器环境（s6 container_environment）
# dump 到 /tmp/container-env，这里逐行导入
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

  # 运行期 VNC 密码：~/.vnc/passwd 不存在时，用 VNC_PASSWORD（未设置则用默认值）
  # 生成。放 cont-init 而不是 vnc/start.sh：start.sh 直接以 sam 运行，无法 chown、
  # 也无法可靠地拿到容器 -e 变量；cont-init 以 root 跑且能用 with-contenv。
  # 这里还负责把容器环境（s6 container_environment）导出给桌面会话，
  # start.sh 以 sam 运行拿不到这些变量。
  cat > /etc/cont-init.d/15-vnc-password << 'EOF'
#!/command/with-contenv bash
RUN_USER="sam"
HOME_DIR="/deployment/accounts/${RUN_USER}"
PASSWD_FILE="${HOME_DIR}/.vnc/passwd"
ENV_FILE="/tmp/container-env"
ENV_DIR="/run/s6/container_environment"
# 默认密码：不设 VNC_PASSWORD 时使用，保证桌面镜像开箱即用。
# 这是写在镜像里的公开默认值，生产环境务必用 -e VNC_PASSWORD=... 覆盖。
DEFAULT_VNC_PASSWORD="Sam.5H8g"

# 导出容器环境变量供桌面会话导入（xstartup 不走 PAM）。
# 数据源必须是 s6 的 container_environment 目录：s6-svscan 会 re-exec，
# /proc/1/environ 里只剩 PATH，拿不到容器 -e 变量。
# HOME/USER/PWD 等由 VNC 会话自己设定，导进去会被容器默认值（HOME=/root）
# 覆盖，桌面直接坏掉；密码类变量不落盘。文件 600 且属主 sam。
( umask 077
  for f in "${ENV_DIR}"/*; do
    [ -f "${f}" ] || continue
    name="${f##*/}"
    case "${name}" in
      SAM_PASSWORD|VNC_PASSWORD|REDIS_PASSWORD|HOME|USER|LOGNAME|PWD|OLDPWD|SHLVL|_) continue ;;
    esac
    # 值里的换行会破坏 xstartup 的逐行导入，压成空格
    printf '%s=%s\n' "${name}" "$(tr '\n' ' ' < "${f}")"
  done > "${ENV_FILE}" ) || true
chown "${RUN_USER}:${RUN_USER}" "${ENV_FILE}" 2>/dev/null || true
chmod 600 "${ENV_FILE}" 2>/dev/null || true

# 已存在的密码文件优先：通常来自 -v 挂载，是比环境变量更明确的来源
if [ -s "${PASSWD_FILE}" ]; then
  echo "[vnc] 使用已存在的 ${PASSWD_FILE}（忽略 VNC_PASSWORD）"
  exit 0
fi

# 未设置或为空：回落到默认密码，否则桌面起不来
if [ -z "${VNC_PASSWORD}" ]; then
  VNC_PASSWORD="${DEFAULT_VNC_PASSWORD}"
  echo "[vnc] 未设置 VNC_PASSWORD，使用默认密码（生产环境请用 -e VNC_PASSWORD=... 覆盖）"
fi

umask 077
mkdir -p "$(dirname "${PASSWD_FILE}")"
# TigerVNC 的 VNC 认证口令只使用前 8 个字符，更长部分会被静默截断
# 用绝对路径：cont-init 的 PATH 不一定包含 /command
if printf '%s\n' "${VNC_PASSWORD}" | /command/s6-setuidgid "${RUN_USER}" vncpasswd -f > "${PASSWD_FILE}"; then
  chown "${RUN_USER}:${RUN_USER}" "$(dirname "${PASSWD_FILE}")" "${PASSWD_FILE}" 2>/dev/null || true
  chmod 600 "${PASSWD_FILE}"
  echo "[vnc] 已根据 VNC_PASSWORD 生成 ${PASSWD_FILE}"
else
  rm -f "${PASSWD_FILE}"
  echo "[vnc] 根据 VNC_PASSWORD 生成密码文件失败" >&2
  exit 1
fi
EOF
  chmod 0755 /etc/cont-init.d/15-vnc-password

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
# 密码文件由 cont-init 15-vnc-password 生成（默认密码，或 -e VNC_PASSWORD
# 覆盖，或挂载 ~/.vnc/passwd 优先）。缺失说明生成失败，tigervnc 在非交互
# 环境里会挂住或失败，这里直接给出可操作的错误。
if [ ! -s "${HOME}/.vnc/passwd" ]; then
  echo "[vnc] 缺少 ${HOME}/.vnc/passwd：请查看 15-vnc-password 的日志，或用 -e VNC_PASSWORD=... 指定密码" >&2
  exit 1
fi
# 容器环境变量由 cont-init 15-vnc-password 以 root 从 s6 container_environment
# 导出到 /tmp/container-env。缺失时补个空文件，别让 VNC 起不来。
[ -e /tmp/container-env ] || : > /tmp/container-env || true
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
