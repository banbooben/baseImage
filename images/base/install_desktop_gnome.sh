#!/bin/bash
source /deployment/scripts/common.sh
# 复用 desktop 变体（xfce）里与桌面环境无关的部分：
#   setEnv / installVncRuntime / initVncConfig / initDesktopConfig /
#   initInputMethodConfig
# install_desktop.sh 末尾的 autoExecuteFunc 有 BASH_SOURCE 守卫，source 时不会执行。
source /tmp/install_desktop.sh

installGnomeDesktop() {
  detect_distro || return 1
  if [ "$DISTRO_FAMILY" != "debian" ]; then
    echo "desktop-gnome 变体仅支持 Ubuntu：ubuntu-desktop-minimal 是 Ubuntu 专有的 GNOME 打包" >&2
    return 1
  fi

  echo "Installing GNOME desktop..."
  # 失败必须向上传递（同 install_desktop.sh：脚本无 set -e，吞掉失败会推出
  # 一份没有任何桌面组件的镜像）。Dockerfile 另有构建期断言兜底。
  pkg_update || return 1

  # ubuntu-desktop-minimal：GNOME 核心桌面（gnome-shell / gnome-session /
  # nautilus / gnome-terminal 等）。pkg_install 统一带 --no-install-recommends，
  # 否则 Recommends 里的 snapd 与 firefox（1:1snap1 过渡包）会被拉进来——
  # 容器里没有 snapd 运行环境，装了只会变大且不可用。
  pkg_install ubuntu-desktop-minimal || return 1

  # VNC / X11 / 输入法 / 字体：与 xfce 变体同一套
  pkg_install \
      tightvncserver \
      tigervnc-standalone-server \
      tigervnc-common \
      autocutsel \
      openssl \
      websockify \
      xorg \
      xdg-utils \
      dbus-x11 \
      fcitx5 fcitx5-chinese-addons \
      fcitx5-frontend-gtk3 fcitx5-frontend-gtk2 fcitx5-frontend-qt5 \
      fcitx5-module-cloudpinyin \
      fonts-wqy-zenhei fonts-wqy-microhei \
      python3-numpy || return 1

  # Xvnc 没有硬件 GL，gnome-shell 在 X11 下靠 llvmpipe 软件渲染；
  # 缺 mesa 的 dri 驱动会直接崩（"Oh no! Something has gone wrong"）。
  pkg_install mesa-utils libgl1-mesa-dri || return 1

  # gnome-session 的 ubuntu 会话把 Power 守护进程列为必需组件（RequiredComponents），
  # 而它依赖 org.freedesktop.login1（systemd-logind）。s6 基座没有 logind，该进程
  # 退出后 gnome-session 会弹出 "Something went wrong"。生成一个去掉 Power 的
  # ubuntu-vnc 会话，其余组件保持发行版原样（升级后自动跟随，只过滤这一项）。
  local sessions_dir="/usr/share/gnome-session/sessions"
  sed 's/org.gnome.SettingsDaemon.Power;//' \
      "${sessions_dir}/ubuntu.session" > "${sessions_dir}/ubuntu-vnc.session"

  # noble（GNOME 46）的 ubuntu-session 同时提供 Wayland 与 Xorg 会话：
  # /usr/share/xsessions/ubuntu-xorg.desktop 的 Exec 就是下面这条命令。
  # resolute（GNOME 50）只有 Wayland 会话，届时这里要换成 Wayland 原生远程
  # 方案（gnome-remote-desktop / wayvnc），而不是 TigerVNC。
  installVncRuntime \
      "env GNOME_SHELL_SESSION_MODE=ubuntu gnome-session --session=ubuntu-vnc"
}

# GNOME 会话需要 system bus：gnome-session 连不上 /run/dbus/system_bus_socket 会
# 直接 abort（"Failed to connect to system bus"）。s6 基座没有 systemd，
# 这个 socket 不会自己出现；xfce 不依赖 system bus，所以这是 GNOME 变体独有的一步。
#
# 同时清理 /run/systemd：gnome-shell 用 /run/systemd/seats 是否存在判断
# "系统由 systemd 管理"，存在就走 logind 分支（见 gnome-shell 的
# loginManager.js）。s6 基座没有 logind，走那条分支会因 D-Bus JS 异常直接退出；
# 清掉后 shell 回退到 dummy login manager。apt postinst 会在镜像里留下这些空目录。
initSystemBus() {
  mkdir -p /etc/cont-init.d
  cat > /etc/cont-init.d/05-dbus-system <<'EOF'
#!/command/with-contenv bash
rm -rf /run/systemd
mkdir -p /run/dbus
if [ ! -S /run/dbus/system_bus_socket ]; then
  dbus-daemon --system --fork --nopidfile || true
fi
EOF
  chmod 0755 /etc/cont-init.d/05-dbus-system
}

autoExecuteFunc setEnv installGnomeDesktop initVncConfig initDesktopConfig initInputMethodConfig initSystemBus
