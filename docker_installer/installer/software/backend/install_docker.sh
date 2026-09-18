#!/bin/bash
source /deployment/scripts/common.sh

# Install latest docker (no major series pin).
#
#   Debian 系：Docker 官方 apt 源（docker-ce + buildx/compose 插件）
#   openEuler：发行版自带 moby-engine。注意不要选 docker-engine——它仍停在
#              18.09（2018 年），openEuler 24.03 里 moby-engine 才是 25.x。
#              发行版不提供 buildx / compose v2 插件，取上游静态二进制补齐。

# docker CLI 插件的系统级搜索路径（docker 会依次查找这几处）
DOCKER_CLI_PLUGIN_DIR=/usr/libexec/docker/cli-plugins

initConfigFile(){
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
    "registry-mirrors": [
        "https://1l41wjhf.mirror.aliyuncs.com"
    ],
    "storage-driver": "overlay2",
    "default-address-pools": [
        {"base": "172.17.0.0/12", "size": 24}
    ]
}
EOF
}

install_docker_apt(){
  install -m 0755 -d /etc/apt/keyrings
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release software-properties-common
  curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(deb_arch) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu \
    $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  apt-get autoremove -y software-properties-common ca-certificates gnupg
}

# 从 GitHub release 拉 buildx / compose v2 静态二进制（发行版源里没有）
install_cli_plugins(){
  local arch buildx_arch
  arch="$(deb_arch)"
  case "$arch" in
    amd64) buildx_arch="amd64" ;;
    arm64) buildx_arch="arm64" ;;
    *) echo "不支持的架构: $arch" >&2; return 1 ;;
  esac

  local buildx_ver compose_ver
  # BUILDX_PIN_VERSION / COMPOSE_PIN_VERSION 可钉死版本（不带 v 前缀）
  buildx_ver="$(resolve_github_latest_tag docker/buildx BUILDX_PIN_VERSION)" || return 1
  compose_ver="$(resolve_github_latest_tag docker/compose COMPOSE_PIN_VERSION)" || return 1

  mkdir -p "${DOCKER_CLI_PLUGIN_DIR}"

  echo "Installing docker-buildx ${buildx_ver} / docker-compose ${compose_ver} (${arch})"
  # compose 的 release 资产名用 x86_64/aarch64，buildx 用 amd64/arm64
  local compose_arch
  case "$arch" in
    amd64) compose_arch="x86_64" ;;
    arm64) compose_arch="aarch64" ;;
  esac

  curl -fsSL -o "${DOCKER_CLI_PLUGIN_DIR}/docker-buildx" \
    "https://github.com/docker/buildx/releases/download/v${buildx_ver}/buildx-v${buildx_ver}.linux-${buildx_arch}" \
    || return 1
  curl -fsSL -o "${DOCKER_CLI_PLUGIN_DIR}/docker-compose" \
    "https://github.com/docker/compose/releases/download/v${compose_ver}/docker-compose-linux-${compose_arch}" \
    || return 1
  chmod 0755 "${DOCKER_CLI_PLUGIN_DIR}/docker-buildx" "${DOCKER_CLI_PLUGIN_DIR}/docker-compose"

  # 插件必须叫 docker-buildx / docker-compose，且 docker 从 PATH 找不到它们时
  # 会回落到 cli-plugins 目录；加软链让 `buildx` / `docker-compose` 也能直接跑
  ln -sf "${DOCKER_CLI_PLUGIN_DIR}/docker-buildx" /usr/local/bin/docker-buildx
  ln -sf "${DOCKER_CLI_PLUGIN_DIR}/docker-compose" /usr/local/bin/docker-compose

  docker buildx version || return 1
  docker compose version || return 1
}

installDocker(){
  if [ "$DISTRO_FAMILY" = "debian" ]; then
    install_docker_apt
  else
    # containerd 由 moby-engine 依赖带入，显式列出以固定版本来源
    pkg_install moby-engine containerd
    install_cli_plugins
  fi

  docker --version || return 1
  dockerd --version || return 1
}

autoExecuteFunc installDocker initConfigFile
