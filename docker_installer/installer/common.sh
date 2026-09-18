#!/bin/bash
# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
RESET='\033[0m'
BOLD='\033[1m'

# ─────────────────────────────────────────────────────────────────────────────
# 发行版抽象层
#
# installer 脚本一律通过下面的 pkg_* / build_* helper 与发行版交互，
# 不要直接调用 apt-get / dnf / dpkg —— 否则无法在 openEuler 上复用。
#
#   DISTRO_FAMILY=debian → Ubuntu / Debian
#   DISTRO_FAMILY=rpm    → openEuler / RHEL 系
#
# 包名翻译表只覆盖「两侧不同名」的包，同名包原样透传，便于渐进补齐。
# 表中 openEuler 侧的包名已逐个对照 24.03 LTS 官方源核实过。
# ─────────────────────────────────────────────────────────────────────────────

# 探测发行版族；幂等，可重复调用
detect_distro() {
  if [ -n "${DISTRO_FAMILY:-}" ]; then
    return 0
  fi

  local id="" id_like=""
  if [ -r /etc/os-release ]; then
    id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | head -n1)"
    id_like="$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"' | head -n1)"
  fi

  case "${id,,}" in
    ubuntu|debian|linuxmint|raspbian|kali)
      DISTRO_FAMILY=debian ;;
    openeuler|centos|rhel|fedora|rocky|almalinux|anolis|opencloudos|kylin|uos)
      DISTRO_FAMILY=rpm ;;
    *)
      case "${id_like,,}" in
        *debian*|*ubuntu*)        DISTRO_FAMILY=debian ;;
        *rhel*|*fedora*|*centos*) DISTRO_FAMILY=rpm ;;
        *)
          echo "无法识别的发行版：ID='${id}' ID_LIKE='${id_like}'" >&2
          return 1 ;;
      esac ;;
  esac

  export DISTRO_FAMILY
  # 走 stderr：本函数会被 $(build_triplet) 之类的命令替换间接调用，
  # 打到 stdout 会把提示语混进调用方的返回值
  echo "检测到发行版族: ${DISTRO_FAMILY} (ID=${id:-unknown})" >&2
}

# Debian 包名 → openEuler/RHEL 包名。一个 Debian 包可以展开成多个 rpm。
_map_debian_to_rpm() {
  case "$1" in
    # ── 编译工具链 ──
    build-essential)                                 echo "gcc gcc-c++ make" ;;
    pkg-config)                                      echo "pkgconf" ;;

    # ── Python / Redis 编译依赖 ──
    libssl-dev)                                      echo "openssl-devel" ;;
    libffi-dev)                                      echo "libffi-devel" ;;
    libsqlite3-dev)                                  echo "sqlite-devel" ;;
    libbz2-dev)                                      echo "bzip2-devel" ;;
    libreadline-dev)                                 echo "readline-devel" ;;
    libncurses5-dev|libncurses-dev|libncursesw5-dev) echo "ncurses-devel" ;;
    liblzma-dev)                                     echo "xz-devel" ;;
    xz-utils)                                        echo "xz" ;;
    tk-dev)                                          echo "tk-devel" ;;
    libxml2-dev)                                     echo "libxml2-devel" ;;
    libxmlsec1-dev)                                  echo "xmlsec1-devel" ;;
    libexpat1-dev)                                   echo "expat-devel" ;;
    libgdbm-dev|libgdbm-compat-dev)                  echo "gdbm-devel" ;;
    libnss3-dev)                                     echo "nss-devel" ;;
    libdb5.3-dev)                                    echo "libdb-devel" ;;
    uuid-dev)                                        echo "util-linux-devel" ;;
    libbluetooth-dev)                                echo "bluez-devel" ;;
    libcurl4-openssl-dev)                            echo "libcurl-devel" ;;
    libpcre2-dev)                                    echo "pcre2-devel" ;;
    zlib1g-dev)                                      echo "zlib-devel" ;;

    # ── 基础工具 ──
    gnupg|dirmngr)                                   echo "gnupg2" ;;
    locales)                                         echo "glibc-all-langpacks" ;;
    openssh-client)                                  echo "openssh-clients" ;;
    vim)                                             echo "vim-enhanced" ;;

    # ── 中文字体（openEuler 的 wqy 包在 OS 源内，可直接安装）──
    fonts-wqy-zenhei|ttf-wqy-zenhei)                 echo "wqy-zenhei-fonts" ;;
    fonts-wqy-microhei|ttf-wqy-microhei)             echo "wqy-microhei-fonts" ;;

    # ── 桌面运行时库 ──
    libgtk-3-0)                                      echo "gtk3" ;;
    libnss3|libnspr4)                                echo "nss" ;;
    libasound2|libasound2t64)                        echo "alsa-lib" ;;
    libgl1|libglx0|libegl1)                          echo "mesa-libGL" ;;
    libgbm1)                                         echo "mesa-libgbm" ;;
    libglib2.0-0)                                    echo "glib2" ;;
    libfreetype6)                                    echo "freetype" ;;
    libxslt1.1)                                      echo "libxslt" ;;
    libcairo2)                                       echo "cairo" ;;
    libcups2)                                        echo "cups-libs" ;;
    libdrm2)                                         echo "libdrm" ;;
    libpango-1.0-0)                                  echo "pango" ;;
    libx11-6)                                        echo "libX11" ;;
    libxcb1)                                         echo "libxcb" ;;
    libxcomposite1)                                  echo "libXcomposite" ;;
    libxdamage1)                                     echo "libXdamage" ;;
    libxfixes3)                                      echo "libXfixes" ;;
    libxkbcommon0)                                   echo "libxkbcommon" ;;
    libxrandr2)                                      echo "libXrandr" ;;
    libxtst6)                                        echo "libXtst" ;;
    libssl3|libssl3t64)                              echo "openssl-libs" ;;
    libqt5core5a|libqt5dbus5|libqt5gui5|libqt5widgets5|libqt5x11extras5)
                                                     echo "qt5-qtbase" ;;
    libayatana-appindicator3-1)                      echo "libappindicator-gtk3" ;;
    libwebkit2gtk-4.1-0)                             echo "webkit2gtk4.1" ;;
    libatk1.0-0)                                     echo "atk" ;;
    libatk-bridge2.0-0)                              echo "at-spi2-atk" ;;
    libatspi2.0-0)                                   echo "at-spi2-core" ;;
    libxss1)                                         echo "libXScrnSaver" ;;
    libexpat1)                                       echo "expat" ;;
    librsvg2-2)                                      echo "librsvg2" ;;
    libva-drm2|libva-wayland2|libva-x11-2)           echo "libva" ;;
    fonts-liberation)                                echo "liberation-fonts" ;;
    fonts-noto-cjk)                                  echo "google-noto-cjk-fonts" ;;
    fonts-noto-color-emoji)                          echo "google-noto-emoji-fonts" ;;

    # ── 桌面会话 ──
    # openEuler 无 autocutsel。xclip 不是等价替代（它是一次性工具，
    # 不做 PRIMARY<->CLIPBOARD 持续同步），所以映射为空，
    # 由 xfce4-clipman-plugin（在 xfce4-goodies 清单内）承担剪贴板同步。
    autocutsel)                                      echo "" ;;
    tightvncserver|tigervnc-standalone-server|tigervnc-common)
                                                     echo "tigervnc-server" ;;
    # openEuler 无 xorg-x11-server-Xorg；Xvnc 自带 X server，装工具集即可
    xorg)                                            echo "xorg-x11-utils xorg-x11-xinit" ;;
    websockify)                                      echo "python3-websockify" ;;

    # openEuler 没有 xfce4 / xfce4-goodies 元包，改用组件清单等价展开。
    # 注意核心包名是 Thunar（首字母大写），与上游 tarball 一致。
    xfce4)                                           echo "xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfce4-appfinder Thunar garcon exo tumbler xfce4-power-manager xfce4-notifyd" ;;
    xfce4-goodies)                                   echo "thunar-archive-plugin thunar-media-tags-plugin thunar-volman tumbler-extras xfce4-clipman-plugin xfce4-cpugraph-plugin xfce4-cpufreq-plugin xfce4-datetime-plugin xfce4-dict-plugin xfce4-diskperf-plugin xfce4-eyes-plugin xfce4-fsguard-plugin xfce4-genmon-plugin xfce4-mailwatch-plugin xfce4-mount-plugin xfce4-netload-plugin xfce4-notes-plugin xfce4-places-plugin xfce4-screenshooter xfce4-systemload-plugin xfce4-taskmanager xfce4-terminal xfce4-timer-plugin xfce4-weather-plugin xfce4-whiskermenu-plugin xfce4-xkb-plugin" ;;

    # ── 中文输入法：openEuler 只有 fcitx4（无 fcitx5）──
    # openEuler 没有 fcitx 的 GTK immodule，GTK 应用需改走 XIM
    # （GTK_IM_MODULE=xim），所以 frontend-gtk* 映射为空，由调用方按需过滤。
    fcitx5)                                          echo "fcitx fcitx-libs" ;;
    fcitx5-chinese-addons)                           echo "fcitx-libpinyin" ;;
    fcitx5-frontend-gtk3|fcitx5-frontend-gtk2)       echo "" ;;
    fcitx5-frontend-qt5)                             echo "fcitx-qt5" ;;
    fcitx5-module-cloudpinyin)                       echo "fcitx-cloudpinyin" ;;
    fcitx5-configtool)                               echo "fcitx-configtool" ;;

    *)
      echo "$1" ;;
  esac
}

# 把一串「Debian 风格包名」翻译成目标发行版可用的包名
map_packages() {
  detect_distro || return 1

  if [ "$DISTRO_FAMILY" = "debian" ]; then
    echo "$*"
    return 0
  fi

  local out="" p mapped m
  for p in "$@"; do
    mapped="$(_map_debian_to_rpm "$p")"
    # 映射结果可能为空（该包在目标发行版上无对应物），跳过避免空参数
    [ -z "$mapped" ] && continue
    # 多个 Debian 包可能折叠成同一个 rpm（如 tightvncserver/tigervnc-common
    # → tigervnc-server），去重避免 dnf 命令行出现重复参数
    for m in $mapped; do
      case " ${out} " in
        *" ${m} "*) ;;
        *) out="${out} ${m}" ;;
      esac
    done
  done
  echo "${out# }"
}

# ── 包管理器封装 ─────────────────────────────────────────────────────────────

pkg_update() {
  detect_distro || return 1
  case "$DISTRO_FAMILY" in
    debian) apt-get update ;;
    rpm)    dnf makecache -y ;;
  esac
}

# 安装包；包名按 Debian 习惯书写，自动翻译。用法：pkg_install git curl libssl-dev
pkg_install() {
  detect_distro || return 1
  local pkgs
  pkgs="$(map_packages "$@")" || return 1

  echo "安装软件包 (${DISTRO_FAMILY}): ${pkgs}"
  case "$DISTRO_FAMILY" in
    debian)
      # shellcheck disable=SC2086
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${pkgs} ;;
    rpm)
      # shellcheck disable=SC2086
      dnf install -y --setopt=install_weak_deps=False ${pkgs} ;;
  esac
}

pkg_clean() {
  detect_distro || return 1
  case "$DISTRO_FAMILY" in
    debian)
      apt-get autoremove -y
      apt-get clean -y
      apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false
      rm -rf /var/lib/apt/lists/*
      ;;
    rpm)
      dnf clean all -y
      rm -rf /var/cache/dnf/* /var/cache/yum/*
      ;;
  esac
}

# 解包发行版包到指定目录（不安装）
# 用法：pkg_extract <包文件路径> <目标目录>
pkg_extract() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  case "$archive" in
    *.deb) dpkg-deb -x "$archive" "$dest" ;;
    *.rpm) _rpm_extract "$archive" "$dest" ;;
    *) echo "pkg_extract: 不支持的文件类型 ${archive}" >&2; return 1 ;;
  esac
}

# rpm 解包。首选 rpm2cpio | cpio —— 最通用；但有两类包会失败：
#   1. 负载用 lzma-alone 压缩（如 WPS Office），老版 rpm2cpio 解不了；
#   2. 新版本 rpm 里 rpm2cpio 是 rpm2archive 的别名，输出的是 tar 而非 cpio。
# 因此 cpio 路径失败或没产出任何文件时，退回 rpm2archive + tar。
_rpm_extract() {
  local archive="$1" dest="$2"

  if ( cd "$dest" && rpm2cpio "$archive" 2>/dev/null | cpio -idm --quiet 2>/dev/null ) \
     && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    return 0
  fi

  if ! command -v rpm2archive >/dev/null 2>&1; then
    echo "rpm2cpio 解包失败，且系统无 rpm2archive 可退回: ${archive}" >&2
    return 1
  fi

  echo "rpm2cpio 解包失败或结果为空，改用 rpm2archive: ${archive}" >&2
  rm -rf "$dest"; mkdir -p "$dest"

  # rpm2archive 默认把归档写到当前目录的 <包名>.tgz，不接受输出到 stdout 的
  # 稳定写法，故复制到临时目录里跑，再解 tar
  local work
  work="$(mktemp -d)" || return 1
  cp -f "$archive" "${work}/pkg.rpm" || { rm -rf "$work"; return 1; }
  ( cd "$work" && rpm2archive pkg.rpm >/dev/null 2>&1 )

  local tgz=""
  tgz="$(find "$work" -maxdepth 1 -name '*.tgz' | head -n 1)"
  if [ -z "$tgz" ]; then
    echo "rpm2archive 未产出归档: ${archive}" >&2
    rm -rf "$work"
    return 1
  fi

  tar -xzf "$tgz" -C "$dest"
  local rc=$?
  rm -rf "$work"
  [ "$rc" -eq 0 ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]
}

# ── 编译环境 helper（替代 dpkg-* 调用）────────────────────────────────────────

# GNU triplet，用于 ./configure --build
build_triplet() {
  detect_distro || return 1
  case "$DISTRO_FAMILY" in
    debian) dpkg-architecture --query DEB_BUILD_GNU_TYPE ;;
    rpm)
      case "$(uname -m)" in
        x86_64)  echo "x86_64-linux-gnu" ;;
        aarch64) echo "aarch64-linux-gnu" ;;
        *)       echo "$(uname -m)-linux-gnu" ;;
      esac ;;
  esac
}

# 取 rpm 宏的值，未定义时返回空串。
#
# 两个坑：
#   1. 必须用可选形式 %{?name}——%{name} 在宏未定义时，rpm 会把 "%{name}" 这个
#      字面量原样回显且退出码为 0，`|| echo ""` 兜不住，字面量会一路传进 make。
#   2. %build_ldflags 由 openEuler-rpm-config 提供，base 层不装它，未定义是常态；
#      %optflags 则由 rpm 包自身定义。用 %{?} 两种情形都安全。
_rpm_eval_macro() {
  local v
  v="$(rpm --eval "%{?$1}" 2>/dev/null || true)"
  case "$v" in *'%{'*) v="" ;; esac   # 再兜一层：任何没展开的宏都不放行
  printf '%s' "$v"
}

# 发行版推荐的 CFLAGS / LDFLAGS
build_cflags() {
  detect_distro || return 1
  case "$DISTRO_FAMILY" in
    debian) dpkg-buildflags --get CFLAGS ;;
    rpm)    local c; c="$(_rpm_eval_macro optflags)"; printf '%s' "${c:--O2 -g}" ;;
  esac
}

build_ldflags() {
  detect_distro || return 1
  case "$DISTRO_FAMILY" in
    debian) dpkg-buildflags --get LDFLAGS ;;
    # 返回空串是正确结果：Python 的构建脚本用 ${LDFLAGS:-...} 提供
    # rpath 默认值，空串才会走到那个默认值
    rpm)    _rpm_eval_macro build_ldflags ;;
  esac
}

# 让 JDK 的 cacerts 跟随系统信任库（依赖 p11-kit 的 trust 命令）。
# 用法：sync_java_cacerts '$JAVA_HOME/lib/security/cacerts'
# Debian 系由 ca-certificates 的 update.d 钩子在系统证书变更时重跑；
# RHEL 系（openEuler）没有该钩子目录，直接执行一次 trust extract。
sync_java_cacerts() {
  local cacerts="$1"

  command -v trust >/dev/null 2>&1 || {
    echo "sync_java_cacerts: 未找到 trust 命令，跳过（JDK 自带 cacerts 仍可用）" >&2
    return 0
  }

  if [ -d /etc/ca-certificates/update.d ]; then
    # 钩子文件里保留字面量 $JAVA_HOME，由钩子运行时再展开
    cat > /etc/ca-certificates/update.d/docker-openjdk <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
trust extract --overwrite --format=java-cacerts --filter=ca-anchors --purpose=server-auth "${cacerts}"
EOF
    chmod +x /etc/ca-certificates/update.d/docker-openjdk
    /etc/ca-certificates/update.d/docker-openjdk
  else
    # RHEL 系走这条：调用方为了上面那个钩子传的是字面量
    # '$JAVA_HOME/lib/security/cacerts'，这里要的是真实路径，就地展开一次。
    # 不展开的话 trust 会照字面量去建一个名为 "$JAVA_HOME" 的目录，
    # 而 JDK 真正的 cacerts 一直是自带的那些，TLS 信任库不会跟随系统。
    local real_cacerts
    eval "real_cacerts=\"${cacerts}\""
    trust extract --overwrite --format=java-cacerts --filter=ca-anchors --purpose=server-auth "${real_cacerts}"
  fi
}

# 发行版架构名（替代 dpkg --print-architecture）。
# 统一返回 Debian 命名（amd64 / arm64），调用方原有的 case 分支无需改动。
deb_arch() {
  detect_distro || return 1
  case "$DISTRO_FAMILY" in
    debian) dpkg --print-architecture ;;
    rpm)
      case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *)       uname -m ;;
      esac ;;
  esac
}

# sudo 组名：Debian 系用 sudo，RHEL 系用 wheel
sudo_group() {
  detect_distro || return 1
  case "$DISTRO_FAMILY" in
    debian) echo "sudo" ;;
    rpm)    echo "wheel" ;;
  esac
}

# 这些 installer 一律以 root 运行在容器里，此时再套一层 sudo 不只是多余：
# 它把构建绑死在 sudo 的 PAM 配置上。openEuler 基础镜像上 sudo 的 account 阶段
# 会报 "Authentication service cannot retrieve authentication info"，于是
# useradd、写 /etc/environment 这些全部失败。已经是 root 就直接执行。
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# 以指定用户身份执行。root 下同样不再套 sudo。
# setpriv 完全不经过 PAM，优先；但 --reuid 在 util-linux < 2.40 上只认数字，
# 所以先用 id 解析出 uid/gid（openEuler 24.03 是 2.39，不能直接传用户名）。
# runuser 次选：它作为 root 调用时 account 段被 pam_rootok 短路，通常也安全。
as_user() {
  local u="$1"; shift
  if [ "$(id -u)" -ne 0 ]; then
    sudo -u "$u" "$@"
    return
  fi

  local uid gid
  if command -v setpriv >/dev/null 2>&1 &&
     uid="$(id -u "$u" 2>/dev/null)" &&
     gid="$(id -g "$u" 2>/dev/null)"; then
    setpriv --reuid "$uid" --regid "$gid" --init-groups "$@"
  elif command -v runuser >/dev/null 2>&1; then
    runuser -u "$u" -- "$@"
  else
    sudo -u "$u" "$@"
  fi
}

# 启用 openEuler 的 EPOL 仓库。
# Xfce4 / fcitx 等桌面组件全部只在 EPOL 里，基础镜像默认 enabled=0，
# 不打开的话装桌面会直接找不到包。
enable_openeuler_repos() {
  local f found=0

  # openEuler-repos 自带的 openEuler.repo 各段默认 enabled=1，
  # 但精简容器镜像可能被裁掉部分仓库，这里统一兜底打开。
  # debuginfo / source 体积大且构建用不到，保持原样。
  for f in /etc/yum.repos.d/*.repo; do
    [ -f "$f" ] || continue
    grep -qiE '^\[(OS|everything|EPOL|update)\]' "$f" || continue
    found=1
    awk '
      /^\[/ { inseg = (tolower($0) ~ /^\[(os|everything|epol|update)\]$/) }
      inseg && /^[[:space:]]*enabled[[:space:]]*=/ { print "enabled=1"; next }
      { print }
    ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  done

  if [ "$found" = "0" ]; then
    echo "警告: 未找到 openEuler 仓库定义，装包可能失败" >&2
    return 1
  fi
  echo "已启用 openEuler OS/everything/EPOL/update 仓库"
}

# 配置 rpm 系软件源：替换镜像 + 启用必要仓库。
# openEuler 官方源在国内，但企业内网常受限，默认切到 aliyun，
# 可用 OPENEULER_MIRROR 覆盖。
configure_rpm_mirrors() {
  local mirror="${OPENEULER_MIRROR:-https://mirrors.aliyun.com/openeuler}"
  local f changed=0

  for f in /etc/yum.repos.d/*.repo; do
    [ -f "$f" ] || continue
    sed -i -E \
      "s#https?://(repo\.openeuler\.org|dl-cdn\.openeuler\.openatom\.cn)#${mirror}#g" \
      "$f"
    changed=1
  done

  if [ "$changed" = "0" ]; then
    echo "警告: 未找到任何 .repo 文件，跳过镜像替换" >&2
  else
    echo "已将 openEuler 源切换为 ${mirror}"
  fi

  enable_openeuler_repos
}

# Ensure a password env var is set; generate a random value if missing.
# Usage: ensure_password ROOT_PASSWORD
ensure_password() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf -v "$name" '%s' "$(openssl rand -base64 18 | tr -d '=+/')"
    export "$name"
    echo -e "${CYAN}提示: ${name} 未提供，已生成随机密码${RESET}" >&2
  fi
}

beforeInstall(){
  detect_distro || return 1

  echo "配置软件源 (${DISTRO_FAMILY})"
  case "$DISTRO_FAMILY" in
    debian)
      sed -i "s#http://ports.ubuntu.com/#http://mirrors.aliyun.com/#g" /etc/apt/sources.list.d/ubuntu.sources
      ;;
    rpm)
      configure_rpm_mirrors
      ;;
  esac

  ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

  echo "set pip sources"
  mkdir -p ~/.pip
  echo "[global]
     index-url = https://mirrors.aliyun.com/pypi/simple/" > ~/.pip/pip.conf

  pkg_update
}

# Shared HTTP GET for installer version-resolve helpers.
_installer_http_get() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
  else
    return 1
  fi
}

# Resolve latest patch for a Python series (e.g. 3.12 -> 3.12.13).
# Override with PYTHON_PIN_VERSION=3.12.10 to pin a specific release.
resolve_python_latest_version() {
  local series="$1"
  local latest=""

  if [ -n "${PYTHON_PIN_VERSION:-}" ]; then
    echo "$PYTHON_PIN_VERSION"
    return 0
  fi

  latest="$(_installer_http_get "https://endoflife.date/api/python/${series}.json" 2>/dev/null \
    | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1)"

  if [ -z "$latest" ]; then
    local listing base_dir
    listing="$(_installer_http_get "https://www.python.org/ftp/python/" 2>/dev/null || true)"
    # 取该系列最新的基础版本目录（3.14.x 补丁各自成目录；预发布 tar 包也放在 X.Y.0/ 目录里）
    base_dir="$(printf '%s\n' "$listing" \
      | grep -oE "${series}\.[0-9]+/" \
      | sort -Vu \
      | tail -n 1)"
    if [ -n "$base_dir" ]; then
      # 以目录内真实存在的 Python-*.tar.xz 文件名为准解析：
      # 预发布期目录已建但正式 tar 包未上传（如 3.15.0/ 里只有 3.15.0rc2），
      # 按目录名解析会得到不存在的版本导致 404
      latest="$(_installer_http_get "https://www.python.org/ftp/python/${base_dir}" 2>/dev/null \
        | grep -oE "Python-${series}\.[0-9]+((a|b|rc)[0-9]+)?\.tar\.xz" \
        | sed 's/^Python-//; s/\.tar\.xz$//' \
        | sort -Vu \
        | tail -n 1)"
    fi
  fi

  if [ -z "$latest" ]; then
    echo "Failed to resolve latest Python version for series ${series}" >&2
    return 1
  fi

  echo "$latest"
}

# Resolve latest OpenJDK update for a major version (e.g. 11 -> 11.0.31+11).
# Override with JAVA_PIN_VERSION=11.0.26+4 to pin a specific release.
resolve_openjdk_latest_version() {
  local major="$1"
  local latest=""
  local next_major=$((major + 1))

  if [ -n "${JAVA_PIN_VERSION:-}" ]; then
    echo "$JAVA_PIN_VERSION"
    return 0
  fi

  latest="$(_installer_http_get "https://api.adoptium.net/v3/info/release_versions?version=%5B${major}%2C${next_major}%29&release_type=ga&page_size=1&sort_method=DATE&sort_order=DESC" 2>/dev/null \
    | sed -n 's/.*"openjdk_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1)"
  latest="${latest%-LTS}"

  if [ -z "$latest" ]; then
    echo "Failed to resolve latest OpenJDK version for major ${major}" >&2
    return 1
  fi

  echo "$latest"
}

# Resolve latest for an endoflife.date product cycle (e.g. redis/7.4 -> 7.4.9).
# Optional pin: pass pin via env named by 3rd arg, or VERSION_PIN.
resolve_eol_latest_version() {
  local product="$1"
  local cycle="$2"
  local pin_env="${3:-VERSION_PIN}"
  local pin_value=""
  local latest=""

  eval "pin_value=\${${pin_env}:-}"
  if [ -n "$pin_value" ]; then
    echo "$pin_value"
    return 0
  fi

  latest="$(_installer_http_get "https://endoflife.date/api/${product}/${cycle}.json" 2>/dev/null \
    | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1)"

  if [ -z "$latest" ]; then
    echo "Failed to resolve latest ${product} version for cycle ${cycle}" >&2
    return 1
  fi

  echo "$latest"
}

# Resolve latest GitHub release tag (strips leading v). Override with VERSION_PIN or 2nd env name.
resolve_github_latest_tag() {
  local repo="$1"
  local pin_env="${2:-VERSION_PIN}"
  local pin_value=""
  local latest=""

  eval "pin_value=\${${pin_env}:-}"
  if [ -n "$pin_value" ]; then
    echo "$pin_value"
    return 0
  fi

  latest="$(_installer_http_get "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\?\([^"]*\)".*/\1/p' \
    | head -n 1)"

  if [ -z "$latest" ]; then
    echo "Failed to resolve latest GitHub release for ${repo}" >&2
    return 1
  fi

  echo "$latest"
}

# Resolve latest Apache Hive version for a series (e.g. 4 or 4.0 -> 4.2.0).
resolve_apache_hive_latest_version() {
  local series="$1"
  local pin_env="${2:-HIVE_PIN_VERSION}"
  local pin_value=""
  local latest=""
  local listing=""

  eval "pin_value=\${${pin_env}:-}"
  if [ -n "$pin_value" ]; then
    echo "$pin_value"
    return 0
  fi

  listing="$(_installer_http_get "https://downloads.apache.org/hive/" 2>/dev/null || true)"
  latest="$(printf '%s\n' "$listing" \
    | grep -oE "hive-${series}(\.[0-9]+)+/" \
    | sed 's#hive-##;s#/##' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -n 1)"

  if [ -z "$latest" ]; then
    listing="$(_installer_http_get "https://archive.apache.org/dist/hive/" 2>/dev/null || true)"
    latest="$(printf '%s\n' "$listing" \
      | grep -oE "hive-${series}(\.[0-9]+)+/" \
      | sed 's#hive-##;s#/##' \
      | sort -t. -k1,1n -k2,2n -k3,3n \
      | tail -n 1)"
  fi

  if [ -z "$latest" ]; then
    echo "Failed to resolve latest Apache Hive version for series ${series}" >&2
    return 1
  fi

  echo "$latest"
}

# Write an s6-overlay container env var (/etc/cont-env.d/KEY).
write_cont_env() {
  local key="$1"
  local value="$2"
  mkdir -p /etc/cont-env.d
  printf '%s' "$value" > "/etc/cont-env.d/${key}"
  export "${key}=${value}"
}

# Register an s6-rc longrun service.
# Usage: register_s6_longrun <name> <path-to-run-script-content-file-or-heredoc via stdin not supported>
# Prefer writing run body with register_s6_longrun_cmd.
register_s6_longrun_cmd() {
  local name="$1"
  local run_body="$2"
  local run_user="${3:-}"
  local svc="/etc/s6-overlay/s6-rc.d/${name}"

  mkdir -p "${svc}/dependencies.d" /etc/s6-overlay/s6-rc.d/user/contents.d
  printf 'longrun\n' > "${svc}/type"
  : > "${svc}/dependencies.d/base"
  : > "/etc/s6-overlay/s6-rc.d/user/contents.d/${name}"

  if [ -n "$run_user" ]; then
    local escaped_body
    escaped_body="$(printf '%q' "${run_body}")"
    cat > "${svc}/run" <<EOF
#!/command/with-contenv bash
exec s6-setuidgid ${run_user} bash -lc "${escaped_body}"
EOF
  else
    cat > "${svc}/run" <<EOF
#!/command/with-contenv bash
${run_body}
EOF
  fi
  chmod 0755 "${svc}/run"
}

# Add an s6-rc dependency: service A depends on B.
register_s6_dependency() {
  local name="$1"
  local dep="$2"
  mkdir -p "/etc/s6-overlay/s6-rc.d/${name}/dependencies.d"
  : > "/etc/s6-overlay/s6-rc.d/${name}/dependencies.d/${dep}"
}

endInstall(){
  pkg_clean
}

executeWithRetry() {
  # 执行指定方法并在失败时重试
  # 参数1: 方法名
  # 参数2: 最大重试次数
  local method="$1"
  local max_retries="$2"
  local retry_count=0

  while [ $retry_count -lt $max_retries ]; do
    # 调用传入的方法
    $method

    # 检查方法退出码
    if [ $? -eq 0 ]; then
      echo "方法执行成功"
      break
    else
      echo "方法执行失败"
      # 增加重试计数
      retry_count=$((retry_count + 1))
      if [ $retry_count -lt $max_retries ]; then
        echo "重试 ($retry_count / $max_retries)..."
        # 避免立即重试
        sleep 1
      else
        echo "已达到最大重试次数，终止脚本"
        exit 1
      fi
    fi
  done
}

autoExecuteFunc(){
  local args=($@)
  echo $args
  # 获取参数数量
  local num_args=${#args[@]}

  beforeInstall

  # 遍历参数并逐个执行
  for ((i=0; i<num_args; i++)); do
    echo "start run function $((i+1)): ${args[$i]}"
    executeWithRetry ${args[$i]} 5
  done

  endInstall
  merge_and_save_env

}

node_is_master(){
  # 获取 Swarm 集群节点列表
  node_list=$(docker node ls --format "{{.ID}}:{{.Hostname}}")

  # 存储 manager 节点信息
  manager_nodes=()

  # 遍历节点并筛选 manager
  while IFS= read -r node_info; do
    node_id=$(echo "$node_info" | cut -d ':' -f 1)
    node_hostname=$(echo "$node_info" | cut -d ':' -f 2)
    node_role=$(docker node inspect --format "{{.Spec.Role}}" "$node_id")

    if [ "$node_role" == "manager" ]; then
      manager_nodes+=("$node_hostname")
    fi

  # 初始化标记
  found=false

  # 检查目标主机是否在 manager 列表中
  for item in "${manager_nodes[@]}"; do
    if [ "$item" == "$1" ]; then
      found=true
      break
    fi
  done

  done <<< "$node_list"

  if [ "$found" == true ]; then
    echo "$1 is manager node"
    return 0
  else
    echo "$1 不是管理节点"
    return 1
  fi

}

create_user() {
    local username=""
    local password=""
    local use_sudo=false
    local no_passwd_sudo=false
    local generate_sshkey=false
    local home_dir=""

    # 参数解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sudo) use_sudo=true ;;
            --nopasswd) no_passwd_sudo=true ;;
            --sshkey) generate_sshkey=true ;;
            --home-dir=*) home_dir="${1#*=}" ;;
            --home-dir)
                [[ $# -ge 2 ]] && { home_dir="$2"; shift; } || {
                    echo -e "${RED}Error: --home-dir requires a path${RESET}"
                    return 1
                }
                ;;
            -*)
                echo -e "${YELLOW}警告: 忽略未知选项 '$1'${RESET}"
                ;;
            *)
                if [[ -z "$username" ]]; then
                    username="$1"
                elif [[ -z "$password" ]]; then
                    password="$1"
                else
                    echo -e "${YELLOW}警告: 忽略多余参数 '$1'${RESET}"
                fi
                ;;
        esac
        shift
    done

    # 校验用户名
    if [[ -z "$username" ]]; then
        echo -e "${RED}错误: 未指定用户名${RESET}"
        echo -e "用法: $0 用户名 [密码] [选项]"
        echo -e "选项:"
        echo -e "  --sudo          add user to sudo/wheel group"
        echo -e "  --nopasswd      配置免密 sudo"
        echo -e "  --sshkey        generate ssh keypair"
        echo -e "  --home-dir=PATH set user home directory"
        return 1
    fi

    # 检查用户是否已存在
    if id "$username" &>/dev/null; then
        echo -e "${RED}错误: 用户 '$username' 已存在${RESET}"
        return 1
    fi

    # 设置默认家目录
    [[ -z "$home_dir" ]] && home_dir="/deployment/accounts/$username"

    # 未提供密码时自动生成随机密码
    if [[ -z "$password" ]]; then
        password=$(openssl rand -base64 12 | tr -d '=+/')
        echo -e "${CYAN}提示: 已为用户 '$username' 生成随机密码${RESET}"
    fi

    # 创建用户
    echo -e "${BLUE}正在创建用户 '$username'...${RESET}"
    echo -e "家目录位置: ${BOLD}$home_dir${RESET}"

    # 确保父目录存在
    as_root mkdir -p "$(dirname "$home_dir")" || {
        echo -e "${RED}父目录创建失败: $(dirname "$home_dir")${RESET}"
        return 1
    }

    # 创建用户并设置家目录
    if ! as_root useradd -m -d "$home_dir" -s /bin/bash "$username"; then
        echo -e "${RED}User creation failed${RESET}"
        return 1
    fi

    # 设置密码
    echo "$username:$password" | as_root chpasswd || {
        echo -e "${RED}Password setup failed${RESET}"
        as_root userdel -r "$username" 2>/dev/null
        return 1
    }

    # 修复目录权限（useradd -m 可能未设置到预期权限）
    as_root chown -R "$username:$username" "$home_dir"
    as_root chmod 700 "$home_dir"

    # 配置 sudo 权限：仅加组不够——若 /etc/sudoers 缺 %sudo 规则会报「不在 sudoers 中」
    # 因此同时写入 /deployment/accounts/sudoers.d（由 initSudoers 引入）
    if [[ "$use_sudo" == true ]]; then
        # Debian 系用 sudo 组，RHEL 系用 wheel
        local sgrp
        sgrp="$(sudo_group)" || return 1
        echo -e "${BLUE}将用户 '$username' 加入 ${sgrp} 组...${RESET}"
        as_root usermod -aG "$sgrp" "$username" || {
            echo -e "${RED}加入 ${sgrp} 组失败${RESET}"
            return 1
        }

        as_root mkdir -p /deployment/accounts/sudoers.d
        local sudoers_file="/deployment/accounts/sudoers.d/${username}"
        if [[ "$no_passwd_sudo" == true ]]; then
            echo -e "${BLUE}配置免密 sudo...${RESET}"
            echo "${username} ALL=(ALL) NOPASSWD:ALL" | as_root tee "$sudoers_file" >/dev/null || {
                echo -e "${RED}Configure passwordless sudo failed${RESET}"
                return 1
            }
        else
            echo "${username} ALL=(ALL:ALL) ALL" | as_root tee "$sudoers_file" >/dev/null || {
                echo -e "${RED}Configure sudoers entry failed${RESET}"
                return 1
            }
        fi
        as_root chmod 440 "$sudoers_file"
        as_root visudo -cf "$sudoers_file" >/dev/null || {
            echo -e "${RED}sudoers 语法校验失败: $sudoers_file${RESET}"
            return 1
        }
    fi

    # 生成 SSH 密钥
    if [[ "$generate_sshkey" == true ]]; then
        echo -e "${BLUE}生成 SSH 密钥对...${RESET}"
        as_user "$username" mkdir -p "$home_dir/.ssh"
        as_user "$username" chmod 700 "$home_dir/.ssh"
        if ! as_user "$username" ssh-keygen -t rsa -b 4096 -f "$home_dir/.ssh/id_rsa" -N "" -q; then
            echo -e "${RED}SSH key generation failed${RESET}"
            return 1
        fi
        as_user "$username" cp "$home_dir/.ssh/id_rsa.pub" "$home_dir/.ssh/authorized_keys"
        as_user "$username" chmod 600 "$home_dir/.ssh/authorized_keys"
        echo -e "${GREEN}SSH 私钥路径: $home_dir/.ssh/id_rsa${RESET}"
    fi

    # 输出结果（不打印明文密码，避免进入构建日志）
    echo -e "\n${BOLD}${GREEN}=== 用户创建成功 ===${RESET}"
    echo -e "${YELLOW}用户名:${RESET} $username"
    echo -e "${YELLOW}密码:${RESET} 已设置（明文不输出）"
    echo -e "${YELLOW}家目录:${RESET} $home_dir"
    [[ "$use_sudo" == true ]] && echo -e "${YELLOW}权限:${RESET} sudo 用户"
    [[ "$no_passwd_sudo" == true ]] && echo -e "${YELLOW}Sudo 策略:${RESET} 免密"
    [[ "$generate_sshkey" == true ]] && echo -e "${YELLOW}SSH 密钥:${RESET} 已生成 ($home_dir/.ssh/id_rsa)"
}

merge_and_save_env() {
    local env_dir="/etc/environments"
    local target_file="/etc/environment"
    local temp_file=$(mktemp)
    local filter_regex='^(PATH|PWD|HOME|HOSTNAME|SHLVL|_)='

    echo "=== 开始合并并保存环境变量 ==="

    # 1. 处理 /etc/environment 中已有变量
    if [[ -f "$target_file" ]]; then
        echo "读取 $target_file 中已有变量..."
        while IFS= read -r line; do
            if [[ "$line" =~ ^([^=]+)= ]]; then
                local key="${BASH_REMATCH[1]}"
                echo "$line" >> "$temp_file"
            fi
        done < "$target_file"
    fi

    # 2. 添加当前环境变量
    echo "添加当前环境变量..."
    env | grep -Ev "$filter_regex" | while read -r line; do
        local key="${line%%=*}"
        local value="${line#*=}"
        if grep -q "^${key}=" "$temp_file"; then
            sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$temp_file"
        else
            echo "${key}=\"${value}\"" >> "$temp_file"
        fi
    done

    # 3. 合并 /etc/environments/env-* 中的变量
    if [[ -d "$env_dir" ]]; then
        echo "合并 $env_dir 中的环境变量..."
        for env_file in "$env_dir"/env-*; do
            if [[ -f "$env_file" ]]; then
                while IFS= read -r line; do
                    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
                        local key="${BASH_REMATCH[1]}"
                        local value="${BASH_REMATCH[2]}"
                        if grep -q "^${key}=" "$temp_file"; then
                            sed -i "s|^${key}=.*|${key}=${value}|" "$temp_file"
                        else
                            echo "${key}=${value}" >> "$temp_file"
                        fi
                    fi
                done < "$env_file"
            fi
        done
    fi

    # 4. 删除代理相关变量
    echo "清理代理相关变量..."
    sed -i '/^\(http\|https\|ftp\)_proxy=/Id' "$temp_file"
    sed -i '/^\(HTTP\|HTTPS\|FTP\)_PROXY=/Id' "$temp_file"
    sed -i '/^\(no_proxy\|NO_PROXY\)=/Id' "$temp_file"

    # 5. 更新 /etc/environment
    echo "更新 $target_file 文件..."
    as_root cp "$temp_file" "$target_file"
    as_root chmod 644 "$target_file"
    rm -f "$temp_file"

    # 6. 删除 /etc/environments 目录
    if [[ -d "$env_dir" ]]; then
        echo "删除目录 $env_dir..."
        as_root rm -rf "$env_dir"
    fi

    echo "=== 环境变量合并和保存完成 ==="
    echo "文件路径: $target_file"
    echo "当前内容摘要:"
    as_root cat "$target_file"
}
