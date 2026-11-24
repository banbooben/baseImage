#!/bin/bash
source /deployment/scripts/common.sh
# 复用 install_desktop.sh 里与桌面环境无关的公共函数：
#   setEnv / initSystemBus
# VNC 那套（installVncRuntime / initVncConfig / initDesktopConfig）本变体不用：
# resolute（26.04）的 GNOME 50 只有 Wayland 会话，远程桌面改由
# gnome-remote-desktop 的 headless RDP 提供，不再需要 Xvnc / noVNC。
# install_desktop.sh 末尾的 autoExecuteFunc 有 BASH_SOURCE 守卫，source 时不会执行。
source /tmp/install_desktop.sh

installRdpDesktop() {
  detect_distro || return 1
  if [ "$DISTRO_FAMILY" != "debian" ]; then
    echo "desktop-rdp 变体仅支持 Ubuntu：依赖 GNOME 50 与 gnome-remote-desktop 的 headless RDP" >&2
    return 1
  fi

  echo "Installing GNOME (Wayland) + gnome-remote-desktop (RDP)..."
  # 失败必须向上传递（同其它变体：脚本无 set -e，吞掉失败会推出一份没有
  # 桌面/没有 RDP 服务的镜像）。Dockerfile 另有构建期断言兜底。
  pkg_update || return 1

  # ubuntu-desktop-minimal：GNOME 核心桌面（与 desktop-gnome 变体同一套）。
  # pkg_install 统一带 --no-install-recommends，避免拉进 snapd / firefox 过渡包。
  pkg_install ubuntu-desktop-minimal || return 1

  # 远程桌面与 headless 会话的依赖：
  #   gnome-remote-desktop  RDP 服务端（/usr/libexec/gnome-remote-desktop-daemon + grdctl）
  #   fuse3                 RDP 剪贴板文件传输走 FUSE。容器运行期必须挂 /dev/fuse，
  #                         否则客户端一连上守护进程就 g_error 退出（见 README）
  #   pipewire/wireplumber  GRD 的画面来源是 PipeWire 的 ScreenCast 流
  #   python3-gi            rdp-primary-monitor（把 GRD 的虚拟显示器切成主显示器）
  #   ibus/ibus-libpinyin   中文输入法。Wayland 会话里 GTK/Qt 走输入法协议，
  #                         X11 变体用的 fcitx5 在这里不参与输入，GNOME 内建的是 ibus
  pkg_install \
      gnome-remote-desktop fuse3 \
      pipewire wireplumber \
      openssl python3-gi \
      ibus ibus-libpinyin \
      fonts-wqy-zenhei fonts-wqy-microhei || return 1

  relocateFusermount3
}

# Ubuntu 25.10 / 26.04 的 apparmor 包自带 /etc/apparmor.d/fusermount3：profile 按
# 解析后的可执行文件路径 /usr/bin/fusermount3 命中，只放行挂载到 @{HOME}、/tmp、
# /mnt、/media、/run/user/<uid> 等目标。容器里 --security-opt apparmor=unconfined
# 挡不住这种"按文件命中"的 profile：gnome-remote-desktop 在 RDP 客户端连上、开始
# 挂 FUSE 剪贴板时 mount() 返回 EACCES，日志是
#   fusermount3: mount failed: Permission denied
#   ERROR **: [FUSE Clipboard] Failed to mount FUSE filesystem
# 随后守护进程 g_error 退出（整个会话跟着垮）。
# libfuse3 硬编码执行 /usr/bin/fusermount3，所以保留这个路径，把真正的二进制挪到
# /usr/local/libexec 再软链回来——AppArmor 按解析后的目标路径匹配，不再命中该
# profile（已实测：软链后同一容器、同一用户挂载成功）。
relocateFusermount3() {
  if [ -x /usr/bin/fusermount3 ] && [ ! -L /usr/bin/fusermount3 ]; then
    mkdir -p /usr/local/libexec
    mv /usr/bin/fusermount3 /usr/local/libexec/fusermount3
    ln -s ../local/libexec/fusermount3 /usr/bin/fusermount3
    echo "fusermount3 relocated to /usr/local/libexec (bypass Ubuntu AppArmor profile)"
  fi
}

# RDP 会话以 sam 运行，需要家目录属主正确、XDG_RUNTIME_DIR 为该用户 0700 的目录
# （GRD 在 $XDG_RUNTIME_DIR/gnome-remote-desktop/ 下建剪贴板 FUSE 挂载点）。
# 放在 cont-init 里以 root 完成，早于所有服务启动；排在 base 层的 05-puid-pgid
# 之后，这样 PUID/PGID 对齐后拿到的 uid 才是最终的。
initRdpRuntime() {
  mkdir -p /etc/cont-init.d
  cat > /etc/cont-init.d/06-rdp-runtime <<'EOF'
#!/command/with-contenv bash
RUN_USER=sam
HOME_DIR="/deployment/accounts/${RUN_USER}"
# 标准家目录：桌面图标扩展 DING 在 ~/Desktop 不存在时会每 3 秒崩溃重启一次
# （日志里刷 "Error when getting information for file .../Desktop"），
# 文件选择器默认也要指向这些目录。以 root 在 cont-init 里建好，属主是 sam。
for d in Desktop Documents Downloads Music Pictures Public Templates Videos; do
  mkdir -p "${HOME_DIR}/${d}"
done
chown -R "${RUN_USER}:${RUN_USER}" "${HOME_DIR}" 2>/dev/null || true

uid=$(id -u "${RUN_USER}")
mkdir -p "/run/user/${uid}"
chown "${RUN_USER}:${RUN_USER}" "/run/user/${uid}"
chmod 700 "/run/user/${uid}"

# 会话日志（gnome-shell / GRD / pipewire）落在 /deployment/logs，便于排查
mkdir -p /deployment/logs
chown "${RUN_USER}:${RUN_USER}" /deployment/logs 2>/dev/null || true
EOF
  chmod 0755 /etc/cont-init.d/06-rdp-runtime
}

# GRD 只在 RDP 客户端连上时才创建 "Virtual remote monitor"，而 GNOME Shell 只在
# 主显示器上画顶栏与 Dock。不切换的话客户端看到的是一块只有壁纸的空屏。
# 这个守护脚本轮询 org.gnome.Mutter.DisplayConfig，把 GRD 的虚拟显示器设为唯一
# 主显示器；断开后 GRD 删掉显示器，脚本回到等待状态，下次连接重新应用。
initRdpMonitorWatcher() {
  cat > /usr/local/bin/rdp-primary-monitor <<'PYEOF'
#!/usr/bin/python3
"""把 gnome-remote-desktop 创建的虚拟显示器设为唯一/主显示器。

headless 的 gnome-shell 先有一个自己的 Meta-0（--virtual-monitor），GRD 在客户端
连上时才额外创建一个 "Virtual remote monitor"。GNOME Shell 只在主显示器上画顶栏
与 Dock，若不切换，RDP 客户端看到的就只有壁纸。
"""
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

BUS = "org.gnome.Mutter.DisplayConfig"
PATH = "/org/gnome/Mutter/DisplayConfig"
IFACE = "org.gnome.Mutter.DisplayConfig"
STATE_SIG = "(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})"
APPLY_SIG = "(uua(iiduba(ssa{sv}))a{sv})"

conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)


def get_state():
    res = conn.call_sync(BUS, PATH, IFACE, "GetCurrentState", None,
                         GLib.VariantType.new(STATE_SIG),
                         Gio.DBusCallFlags.NONE, -1, None)
    return res.unpack()


def is_remote(product):
    return "remote" in (product or "").lower()


def main():
    applied_for = None
    while True:
        try:
            serial, monitors, logical, _props = get_state()
            remote = [m for m in monitors if is_remote(m[0][2])]
            if not remote:
                applied_for = None
                time.sleep(1)
                continue
            mon = remote[0]
            key = mon[0][0]
            modes = mon[1]
            current = None
            for mode_id, _w, _h, _rate, _scale, _flags, mprops in modes:
                if mprops.get("is-current"):
                    current = mode_id
            if current is None and modes:
                current = modes[0][0]
            # 已经是唯一主显示器就不再重复应用
            if applied_for == key and len(logical) == 1 and logical[0][4]:
                time.sleep(2)
                continue
            cfg = GLib.Variant(
                APPLY_SIG,
                (serial, 1, [(0, 0, 1.0, 0, True, [(key, current, {})])], {}))
            conn.call_sync(BUS, PATH, IFACE, "ApplyMonitorsConfig", cfg,
                           None, Gio.DBusCallFlags.NONE, -1, None)
            applied_for = key
            print(f"primary monitor -> {key} ({current})", flush=True)
        except Exception as exc:  # noqa: BLE001 - 守护脚本不能因单次失败退出
            print(f"watch: {exc}", file=sys.stderr, flush=True)
        time.sleep(2)


if __name__ == "__main__":
    main()
PYEOF
  chmod 0755 /usr/local/bin/rdp-primary-monitor
}

# s6 服务 rdp（longrun）：一条 dbus-run-session 里依次起
# pipewire → headless gnome-shell → 写 GRD 配置 → gnome-remote-desktop 守护进程。
# 守护进程退出（例如客户端异常断开后的致命错误）时整条会话随之结束，
# s6 负责重启，会话回到初始状态。
initRdpService() {
  local svc=/etc/s6-overlay/s6-rc.d/rdp
  mkdir -p "$svc/dependencies.d" /etc/s6-overlay/s6-rc.d/user/contents.d

  printf 'longrun\n' > "$svc/type"

  cat > "$svc/run" <<'EOF'
#!/command/with-contenv bash
# 以 sam 起会话；容器 -e 变量（RESOLUTION / RDP_PORT / RDP_PASSWORD）由
# with-contenv 带进来，再经 s6-setuidgid 传给会话脚本
exec s6-setuidgid sam /etc/s6-overlay/s6-rc.d/rdp/start.sh
EOF

  # 一次会话一条 session bus：gnome-shell、GSettings/dconf、GRD 都在上面。
  cat > "$svc/start.sh" <<'EOF'
#!/bin/bash
set -u
export HOME=/deployment/accounts/sam
export USER=sam
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_SESSION_DESKTOP=ubuntu

mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

exec dbus-run-session -- /etc/s6-overlay/s6-rc.d/rdp/session.sh
EOF

  cat > "$svc/session.sh" <<'EOF'
#!/bin/bash
set -u
HOME_DIR=/deployment/accounts/sam
GRD_DIR="${HOME_DIR}/.local/share/gnome-remote-desktop"
LOG_DIR=/deployment/logs
RESOLUTION="${RESOLUTION:-1920x1080}"
RDP_PORT="${RDP_PORT:-3389}"
# 默认密码：不设 RDP_PASSWORD 时使用，保证镜像开箱可用。
# 这是写在镜像里的公开默认值，生产环境务必用 -e RDP_PASSWORD=... 覆盖。
RDP_PASSWORD="${RDP_PASSWORD:-Sam.5H8g}"

mkdir -p "$GRD_DIR" "$LOG_DIR"

# RDP 服务端要求 NLA，也就必须有 TLS 证书。运行期自签生成，不进镜像；
# 容器持久化 ~/.local/share/gnome-remote-desktop 后客户端只需信任一次。
if [ ! -s "${GRD_DIR}/rdp-tls.crt" ] || [ ! -s "${GRD_DIR}/rdp-tls.key" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -subj "/CN=$(hostname)" \
      -keyout "${GRD_DIR}/rdp-tls.key" -out "${GRD_DIR}/rdp-tls.crt" \
      >"${LOG_DIR}/rdp-tls.log" 2>&1 \
    || echo "[rdp] 生成 TLS 证书失败，见 ${LOG_DIR}/rdp-tls.log" >&2
  chmod 600 "${GRD_DIR}/rdp-tls.key" 2>/dev/null || true
fi

# GRD 的画面来自 PipeWire 的 ScreenCast 流；缺了会在客户端连上时报
# "Failed to start screen cast stream: Couldn't connect pipewire connection"
pipewire >"${LOG_DIR}/rdp-pipewire.log" 2>&1 &
wireplumber >"${LOG_DIR}/rdp-wireplumber.log" 2>&1 &

# --mode=ubuntu 用发行版的 Yaru 主题与扩展集（Ubuntu Dock、指示器、桌面图标）；
# 不给 --mode 时是裸 GNOME，看起来就和官方 Ubuntu 桌面不一样。
gnome-shell --headless --mode=ubuntu --virtual-monitor "$RESOLUTION" \
    >"${LOG_DIR}/rdp-shell.log" 2>&1 &

# 等 shell 的 session bus 名字出现：GSettings 写入走 dconf-service，必须在
# session bus 上；太早写会报 "Cannot autolaunch D-Bus without X11 $DISPLAY"。
for _ in $(seq 1 60); do
  if gdbus introspect --session --dest org.gnome.Shell \
      --object-path /org/gnome/Shell >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# headless 模式的开关不能走 `grdctl --headless rdp enable`：它通过 systemd 单位
# 启停服务，s6 基座没有 systemd（会报 Name "org.freedesktop.systemd1" does not
# exist）。直接写等价的 GSettings 开关。证书/私钥的键在非 headless 的 rdp 域下。
gsettings set org.gnome.desktop.remote-desktop.rdp.headless enable true
gsettings set org.gnome.desktop.remote-desktop.rdp.headless port "$RDP_PORT"
gsettings set org.gnome.desktop.remote-desktop.rdp tls-cert "${GRD_DIR}/rdp-tls.crt"
gsettings set org.gnome.desktop.remote-desktop.rdp tls-key "${GRD_DIR}/rdp-tls.key"

# 中文输入法：Wayland 会话用 GNOME 内建的 ibus（Super+Space 切换）
gsettings set org.gnome.desktop.input-sources sources \
    "[('ibus', 'libpinyin'), ('xkb', 'us')]" \
    >"${LOG_DIR}/rdp-input.log" 2>&1 || true

# RDP 登录凭据：写 ~/.local/share/gnome-remote-desktop/credentials.ini。
# 没有 TPM，GRD 回落到 GKeyFile（文件权限 600）。
grdctl --headless rdp set-credentials sam "$RDP_PASSWORD" \
    >"${LOG_DIR}/rdp-credentials.log" 2>&1 \
  || echo "[rdp] 设置 RDP 凭据失败，见 ${LOG_DIR}/rdp-credentials.log" >&2

# 把 GRD 的虚拟显示器切成主显示器（否则客户端只看到壁纸）
rdp-primary-monitor >"${LOG_DIR}/rdp-watch.log" 2>&1 &

exec /usr/libexec/gnome-remote-desktop-daemon --headless --rdp-port "$RDP_PORT" \
    >"${LOG_DIR}/rdp-grd.log" 2>&1
EOF

  cat > "$svc/finish" <<'EOF'
#!/bin/bash
# 会话进程被 s6 停止时清掉残留的子进程（pipewire / shell / 守护脚本）
for pat in "gnome-remote-desktop-daemon" "gnome-shell --headless" \
           "rdp-primary-monitor" "wireplumber" "pipewire"; do
  pgrep -f "$pat" | xargs -r kill -9 2>/dev/null || true
done
EOF

  printf '' > "$svc/dependencies.d/base"
  printf '' > /etc/s6-overlay/s6-rc.d/user/contents.d/rdp

  chmod 0755 "$svc/run" "$svc/start.sh" "$svc/session.sh" "$svc/finish"
  chmod 0644 "$svc/type" "$svc/dependencies.d/base"
}

autoExecuteFunc setEnv installRdpDesktop initSystemBus initRdpRuntime initRdpMonitorWatcher initRdpService
