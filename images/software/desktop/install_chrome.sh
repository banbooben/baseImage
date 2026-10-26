#!/bin/bash
###
 # Install Chrome & Chromedriver under /deployment/software/chrome.
 # Layer layout (COPY-friendly):
 #   /deployment/software/chrome/               # usr/bin/, usr/lib/, usr/share/
 #   /deployment/software/chrome/data/          # user-data-dir (runtime)
 #   /deployment/bin/chrome                     # launcher
 #   /deployment/bin/chromedriver               # WebDriver launcher
 #
 # 发行版差异：
 #   Debian    ppa:xtradeb/apps 的 chromium（amd64 + arm64），driver 是同源的
 #             chromium-driver 包
 #   openEuler openEuler 全源无 chromium 包，改用 Google Chrome 官方 .rpm
 #             （官方同时发布 x86_64 与 aarch64 两个 .rpm）；
 #             rpm 不含 chromedriver，改从 Chrome for Testing 按同版本补齐
 #             （chromedriver 同样有 linux64 / linux-arm64 两个架构）。
###
source /deployment/scripts/common.sh

CHROME_RPM_BASE=https://dl.google.com/linux/direct
# Chrome for Testing 的公开下载桶（按完整版本号取 chromedriver）
CFT_BASE_URL=https://storage.googleapis.com/chrome-for-testing-public

# Google 官方 .rpm 的架构后缀（两个架构官方都在发布）
chrome_rpm_url(){
  case "$(uname -m)" in
    x86_64|amd64)  echo "${CHROME_RPM_BASE}/google-chrome-stable_current_x86_64.rpm" ;;
    aarch64|arm64) echo "${CHROME_RPM_BASE}/google-chrome-stable_current_aarch64.rpm" ;;
    *) echo "Google Chrome 未发布 $(uname -m) 的 .rpm" >&2; return 1 ;;
  esac
}

# Chrome for Testing 的资产目录名（与 uname -m 不同名）
cft_arch(){
  case "$(uname -m)" in
    x86_64|amd64)  echo "linux64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    *) return 1 ;;
  esac
}

setEnv(){
  export DEBIAN_FRONTEND=noninteractive
  export INSTALL_PATH=/deployment/software/chrome
  export CHROME_DATA="${INSTALL_PATH}/data"

  detect_distro || return 1
  if [ "$DISTRO_FAMILY" = "debian" ]; then
    echo "Chromium (ppa:xtradeb/apps)"
  else
    echo "Google Chrome (official .rpm, $(uname -m))"
  fi
}

installDeps(){
  export DEBIAN_FRONTEND=noninteractive
  pkg_update

  if [ "$DISTRO_FAMILY" = "debian" ]; then
    pkg_install \
      ca-certificates wget software-properties-common \
      libgtk-3-0 libx11-6 libxcb1 libxtst6 libxfixes3 \
      libnss3 libnspr4 libgbm1 \
      libasound2t64 \
      libatk-bridge2.0-0 libatspi2.0-0 \
      libcups2 libdrm2 libxcomposite1 libxdamage1 libxrandr2 \
      libxkbcommon0 libpango-1.0-0 libcairo2 \
      fonts-liberation fonts-noto-cjk fonts-noto-color-emoji \
      xdg-utils
  else
    # openEuler：Google Chrome 是按解包方式装进软件树的，dnf 不会去解析它的
    # 依赖，所以运行期需要的库必须全部显式列出。比 Debian 侧多出的
    # libxss1 / libatk1.0-0 / libexpat1 在 Debian 是由 PPA 的包自动带入的。
    pkg_install \
      ca-certificates wget \
      libgtk-3-0 libx11-6 libxcb1 libxtst6 libxfixes3 \
      libnss3 libnspr4 libgbm1 \
      libasound2t64 \
      libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 \
      libcups2 libdrm2 libxcomposite1 libxdamage1 libxrandr2 \
      libxkbcommon0 libpango-1.0-0 libcairo2 libxss1 libexpat1 \
      fonts-liberation fonts-noto-cjk fonts-noto-color-emoji \
      xdg-utils fontconfig
  fi

  pkg_clean
}

# ── Debian：Chromium PPA（amd64 + arm64 统一）─────────────────
install_chromium_deb(){
  add-apt-repository ppa:xtradeb/apps -y
  pkg_update
  # 注意是 chromium-driver，不是 chromium-chromedriver：
  # 后者只存在于 noble universe，是个指向 chromium snap 的 2.3KB 过渡空包，
  # 装上不会提供 /usr/bin/chromedriver。PPA 里的真包名是 chromium-driver。
  pkg_install chromium chromium-driver libva-drm2 libva-x11-2 libva-wayland2

  # ── 复制到 INSTALL_PATH，保持 COPY-friendly 布局 ─────────────
  local multiarch
  multiarch="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || echo "x86_64-linux-gnu")"

  mkdir -p "${INSTALL_PATH}/usr/bin" \
           "${INSTALL_PATH}/usr/lib/${multiarch}" \
           "${INSTALL_PATH}/usr/share"

  # 二进制（PPA 包名为 chromium，二进制路径 /usr/bin/chromium）
  if [ -x /usr/bin/chromium ]; then
    cp -a /usr/bin/chromium "${INSTALL_PATH}/usr/bin/"
  elif [ -x /usr/bin/chromium-browser ]; then
    cp -a /usr/bin/chromium-browser "${INSTALL_PATH}/usr/bin/"
  fi

  # Chromedriver（与 chromium 版本匹配）
  if [ -x /usr/bin/chromedriver ]; then
    cp -a /usr/bin/chromedriver "${INSTALL_PATH}/usr/bin/"
    echo "Chromedriver copied to ${INSTALL_PATH}/usr/bin/"
  elif [ -x /usr/lib/chromium-browser/chromedriver ]; then
    cp -a /usr/lib/chromium-browser/chromedriver "${INSTALL_PATH}/usr/bin/"
  else
    echo "WARNING: chromedriver not found, WebDriver unavailable" >&2
  fi

  # Chromium 相关的 .so
  if [ -d "/usr/lib/${multiarch}" ]; then
    cp -an "/usr/lib/${multiarch}"/libchromium* "${INSTALL_PATH}/usr/lib/${multiarch}/" 2>/dev/null || true
  fi

  # 资源文件
  for src_dir in /usr/share/chromium /usr/share/chromium-browser; do
    if [ -d "${src_dir}" ]; then
      cp -a "${src_dir}" "${INSTALL_PATH}/usr/share/" 2>/dev/null || true
      break
    fi
  done

  _chrome_version="$(chromium --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)"

  # ── 定位可执行文件 ──────────────────────────────────────────
  if [ -x "${INSTALL_PATH}/usr/bin/chromium" ]; then
    _chrome_bin_path="${INSTALL_PATH}/usr/bin/chromium"
  elif [ -x "${INSTALL_PATH}/usr/bin/chromium-browser" ]; then
    _chrome_bin_path="${INSTALL_PATH}/usr/bin/chromium-browser"
  fi
}

# ── openEuler：Google Chrome 官方 .rpm（x86_64 / aarch64）────
install_chrome_rpm(){
  local rpm_url
  rpm_url="$(chrome_rpm_url)" || return 1

  local tmp="/tmp/google-chrome-stable.rpm"
  local extract_tmp="/tmp/chrome-extract"
  rm -rf "${extract_tmp}" "${tmp}"

  echo "Downloading ${rpm_url}"
  wget -O "${tmp}" "${rpm_url}" || return 1
  pkg_extract "${tmp}" "${extract_tmp}" || { rm -f "${tmp}"; return 1; }

  # rpm 布局：opt/google/chrome 是自包含主目录（chrome 二进制 + 资源），
  # usr/share 下是桌面入口/图标/man。不取 etc/——那是 google-chrome 的
  # cron.daily 自动加官方源的脚本，在容器里既无意义又会在 /etc/yum.repos.d
  # 里留下外部源定义。
  mkdir -p "${INSTALL_PATH}"
  [ -d "${extract_tmp}/opt" ] && mv "${extract_tmp}/opt" "${INSTALL_PATH}/"
  [ -d "${extract_tmp}/usr" ] && mv "${extract_tmp}/usr" "${INSTALL_PATH}/"
  rm -rf "${extract_tmp}"

  local real_bin="${INSTALL_PATH}/opt/google/chrome/google-chrome"
  [ -x "${real_bin}" ] || {
    echo "Google Chrome 主程序缺失: ${real_bin}" >&2
    rm -f "${tmp}"
    return 1
  }

  # rpm 内的 /usr/bin/google-chrome-stable 是指向绝对路径 /opt/google/chrome
  # 的软链，搬进软件树后必然悬空；重指到软件树内的实际位置。
  # google-chrome 是官方启动包装脚本，按自身路径（readlink -f）定位 chrome，
  # 所以整个目录搬走后仍能正常启动。
  ln -sfn "${real_bin}" "${INSTALL_PATH}/usr/bin/google-chrome-stable"

  # google-chrome 包装脚本会 mkdir $HOME/.local/share/applications
  mkdir -p /root/.local/share/applications

  _chrome_version="$("${real_bin}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)"
  if [ -z "${_chrome_version}" ]; then
    # 启动失败（例如缺运行库）时退回 rpm 头里的版本号
    _chrome_version="$(rpm -qp --qf '%{VERSION}' "${tmp}" 2>/dev/null || echo unknown)"
  fi
  rm -f "${tmp}"

  _chrome_bin_path="${real_bin}"

  # rpm 不含 chromedriver，从 Chrome for Testing 按同版本补齐
  install_chromedriver_cft "${_chrome_version}"
}

# Google Chrome 官方 rpm 不带 chromedriver。Chrome for Testing 为每个 stable
# 版本发布配套 driver，按"完整版本号"取；取不到只告警，不阻断镜像构建。
install_chromedriver_cft(){
  local ver="$1"
  [ -n "$ver" ] && [ "$ver" != "unknown" ] || return 0

  local arch_dir
  arch_dir="$(cft_arch)" || return 0      # 未知架构：driver 属可选，跳过即可

  local url="${CFT_BASE_URL}/${ver}/${arch_dir}/chromedriver-${arch_dir}.zip"
  local tmp="/tmp/chromedriver.zip"
  local extract_tmp="/tmp/chromedriver-extract"
  rm -rf "${extract_tmp}" "${tmp}"

  if ! wget -q -O "${tmp}" "${url}"; then
    echo "WARNING: Chrome for Testing 无 ${ver} 的 chromedriver，WebDriver 不可用" >&2
    rm -f "${tmp}"
    return 0
  fi

  mkdir -p "${extract_tmp}"
  if ! unzip -q -o "${tmp}" -d "${extract_tmp}"; then
    echo "WARNING: chromedriver 解压失败，WebDriver 不可用" >&2
    rm -rf "${extract_tmp}" "${tmp}"
    return 0
  fi

  local drv
  drv="$(find "${extract_tmp}" -type f -name chromedriver | head -n 1)"
  if [ -n "${drv}" ]; then
    install -m 0755 "${drv}" "${INSTALL_PATH}/usr/bin/chromedriver"
    echo "Chromedriver (Chrome for Testing ${ver}) copied to ${INSTALL_PATH}/usr/bin/"
  else
    echo "WARNING: 压缩包内未找到 chromedriver，WebDriver 不可用" >&2
  fi
  rm -rf "${extract_tmp}" "${tmp}"
}

installChrome(){
  mkdir -p /deployment/software /deployment/bin
  rm -rf "${INSTALL_PATH}"
  detect_distro || return 1

  # 两个分支各自设置：_chrome_bin_path（可执行文件）、_chrome_version
  _chrome_bin_path=""
  _chrome_version=""

  if [ "$DISTRO_FAMILY" = "debian" ]; then
    install_chromium_deb || return 1
  else
    install_chrome_rpm || return 1
  fi

  if [ -z "${_chrome_bin_path}" ] || [ ! -x "${_chrome_bin_path}" ]; then
    _chrome_bin_path="$(find "${INSTALL_PATH}" -maxdepth 5 -type f -perm -111 \
      \( -name 'chromium*' -o -name 'google-chrome*' -o -name 'chrome' \) 2>/dev/null | head -n 1 || true)"
  fi
  if [ -z "${_chrome_bin_path}" ] || [ ! -x "${_chrome_bin_path}" ]; then
    echo "Chrome binary missing under ${INSTALL_PATH}" >&2
    find "${INSTALL_PATH}" -maxdepth 5 -type f | head -n 60 >&2
    return 1
  fi

  export CHROME_BIN="${_chrome_bin_path}"
  [ -n "${_chrome_version}" ] || \
    _chrome_version="$("${CHROME_BIN}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)"
  CHROME_VERSION="${_chrome_version:-unknown}"
  export CHROME_VERSION

  echo "Chrome version: ${CHROME_VERSION}"
  echo "Chrome binary: ${CHROME_BIN}"

  # Chromedriver 路径
  if [ -x "${INSTALL_PATH}/usr/bin/chromedriver" ]; then
    export CHROMEDRIVER_BIN="${INSTALL_PATH}/usr/bin/chromedriver"
    echo "Chromedriver binary: ${CHROMEDRIVER_BIN}"
  fi

  # ── 运行时数据目录 & 环境持久化 ─────────────────────────────
  mkdir -p "${CHROME_DATA}" /deployment/bin

  write_cont_env CHROME_VERSION "${CHROME_VERSION}"
  write_cont_env CHROME_HOME "${INSTALL_PATH}"
  write_cont_env CHROME_DATA "${CHROME_DATA}"
  write_cont_env CHROME_BIN "${CHROME_BIN}"

  {
    echo "export CHROME_HOME=${INSTALL_PATH}"
    echo "export CHROME_DATA=${CHROME_DATA}"
    echo "export CHROME_BIN=${CHROME_BIN}"
    echo "export CHROME_VERSION=${CHROME_VERSION}"
    echo "export PATH=/deployment/bin:\$PATH"
  } >> /etc/environment

  if [ -n "${CHROMEDRIVER_BIN:-}" ]; then
    write_cont_env CHROMEDRIVER_BIN "${CHROMEDRIVER_BIN}"
    echo "export CHROMEDRIVER_BIN=${CHROMEDRIVER_BIN}" >> /etc/environment
  fi
}

initConfig(){
  local product="Chromium"
  [ "$DISTRO_FAMILY" = "rpm" ] && product="Google Chrome"

  # ── 启动包装脚本 ────────────────────────────────────────────
  cat > "${INSTALL_PATH}/chrome.sh" <<EOF
#!/bin/bash
export CHROME_HOME="\${CHROME_HOME:-${INSTALL_PATH}}"
export CHROME_DATA="\${CHROME_DATA:-${CHROME_DATA}}"
export CHROME_BIN="\${CHROME_BIN:-${CHROME_BIN}}"

mkdir -p "\${CHROME_DATA}"

# 系统库路径（ALSA / GTK / CUPS 等）
ARCH_LIBDIR="/usr/lib/\$(uname -m | sed 's/x86_64/x86_64-linux-gnu/;s/aarch64/aarch64-linux-gnu/')"
export LD_LIBRARY_PATH="\${LD_LIBRARY_PATH:-}:\${ARCH_LIBDIR}:/usr/lib"

# 浏览器自带 lib 目录（Chromium 在 usr/lib，Chrome 在 opt/google/chrome）
for d in "\${CHROME_HOME}/usr/lib"/* "\${CHROME_HOME}/opt/google/chrome"; do
  [ -d "\$d" ] && export LD_LIBRARY_PATH="\${LD_LIBRARY_PATH}:\$d"
done

exec "\${CHROME_BIN}" \\
  --no-sandbox \\
  --disable-gpu \\
  --disable-dev-shm-usage \\
  --user-data-dir="\${CHROME_DATA}" \\
  \${CHROME_OPTS:-} \\
  "\$@"
EOF
  chmod +x "${INSTALL_PATH}/chrome.sh"
  ln -sfn "${INSTALL_PATH}/chrome.sh" /deployment/bin/chrome

  # Chromedriver 启动器
  if [ -x "${INSTALL_PATH}/usr/bin/chromedriver" ]; then
    cat > "${INSTALL_PATH}/chromedriver.sh" <<'EOF'
#!/bin/bash
CHROME_HOME="${CHROME_HOME:-/deployment/software/chrome}"
exec "${CHROME_HOME}/usr/bin/chromedriver" "$@"
EOF
    chmod +x "${INSTALL_PATH}/chromedriver.sh"
    ln -sfn "${INSTALL_PATH}/chromedriver.sh" /deployment/bin/chromedriver
  fi

  # ── 桌面菜单 ────────────────────────────────────────────────
  mkdir -p /usr/share/applications
  local icon=""
  icon="$(find "${INSTALL_PATH}/usr/share" -type f \( -name '*chromium*' -o -name '*chrome*' \) \( -name '*.png' -o -name '*.svg' \) 2>/dev/null | head -n 1 || true)"
  # Google Chrome 的图标在 opt/google/chrome 内，usr/share 下没有
  if [ -z "${icon}" ] && [ -f "${INSTALL_PATH}/opt/google/chrome/product_logo_256.png" ]; then
    icon="${INSTALL_PATH}/opt/google/chrome/product_logo_256.png"
  fi

  cat > /usr/share/applications/chrome.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${product}
Comment=${product} Web Browser
Exec=/deployment/bin/chrome
${icon:+Icon=${icon}}
Terminal=false
Categories=Network;WebBrowser;
EOF

  # ── README ──────────────────────────────────────────────────
  local source_desc="ppa:xtradeb/apps 的 chromium 包"
  [ "$DISTRO_FAMILY" = "rpm" ] && source_desc="Google Chrome 官方 .rpm（解包到软件树）"

  cat > "${INSTALL_PATH}/README.md" <<EOF
# ${product} layer (COPY-friendly)

Installed from ${source_desc} under \`${INSTALL_PATH}\`.
Runtime user data: \`${CHROME_DATA}\`.

\`\`\`dockerfile
COPY --from=<chrome-image> /deployment/software/chrome /deployment/software/chrome
COPY --from=<chrome-image> /deployment/bin/chrome /deployment/bin/chrome
COPY --from=<chrome-image> /deployment/bin/chromedriver /deployment/bin/chromedriver
\`\`\`

Only user-data after use:
\`\`\`dockerfile
COPY --from=<src> /deployment/software/chrome/data /deployment/software/chrome/data
\`\`\`

Browser flags（可通过 CHROME_OPTS 环境变量覆盖）:
  --no-sandbox --disable-gpu --disable-dev-shm-usage

Chromedriver:
  /deployment/bin/chromedriver

注：openEuler 侧装的是 Google Chrome 官方 .rpm（x86_64 / aarch64 均有发布），
driver 来自 Chrome for Testing 的同架构构建。
EOF

  chown -R sarmn:sarmn "${INSTALL_PATH}"

  # chrome-sandbox 必须 root 所有且置 setuid 位；chown 会把它一起改掉。
  # 启动器默认 --no-sandbox 用不到它，但保持规范状态以免有人去掉该参数后困惑。
  local sandbox="${INSTALL_PATH}/opt/google/chrome/chrome-sandbox"
  if [ -f "${sandbox}" ]; then
    chown root:root "${sandbox}"
    chmod 4755 "${sandbox}"
  fi
}

autoExecuteFunc setEnv installDeps installChrome initConfig
