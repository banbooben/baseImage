#!/bin/bash
source /deployment/scripts/common.sh

# Install latest Chromium from apt/PPA (no major series pin).
check_target_arch(){
  ARCH=$(uname -m)

  case $ARCH in
      x86_64|amd64)
          echo "检测到: x86_64 架构"
          TARGET_ARCH="amd64"
          ;;
      aarch64|arm64)
          echo "检测到: ARM64 架构"
          TARGET_ARCH="arm64"
          ;;
      *)
          echo "未知架构: $ARCH"
          exit 1
          ;;
  esac

  echo "目标架构: $TARGET_ARCH"
  export TARGET_ARCH

}


setEnv() {
  # 设置环境变量
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
  export DEBIAN_FRONTEND=noninteractive
  export DISPLAY=:1
  export CHROMIUM_OPTS="--no-sandbox --disable-gpu --disable-dev-shm-usage"
}

installChrome() {
  check_target_arch
  apt-get update
  apt-get install -y --no-install-recommends software-properties-common ca-certificates
  add-apt-repository ppa:xtradeb/apps -y
  apt-get update
  apt-get install -y --no-install-recommends \
    chromium \
    chromium-codecs-ffmpeg \
    libva-drm2 \
    libva-x11-2 \
    libva-wayland2 \
    fonts-liberation \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    language-pack-zh-hans \
    libgbm1 \
    libnss3 \
    libgtk-3-0 \
    libx11-6 \
    libxcb1 \
    libxtst6 \
    libatspi2.0-0 \
    xdg-utils

  apt-get autoremove -y
  apt-get clean -y

}

autoExecuteFunc setEnv installChrome

