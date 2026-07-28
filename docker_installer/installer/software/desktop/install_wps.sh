#!/bin/bash
source /deployment/scripts/common.sh

setEnv() {
  # 设置环境变量
  export PATH="/deployment/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  # Private CDN package; override with WPS_PIN_VERSION / WPS_DEB_URL when publishing a newer build.
  export WPS_VERSION="${WPS_PIN_VERSION:-11.1.0.11723.XA}"
  export WPS_DEB_URL="${WPS_DEB_URL:-http://idps2-static.jq.datagrand.cn/releases/download/wps/wps-office_${WPS_VERSION}_amd64.deb}"
  export DEBIAN_FRONTEND=noninteractive
  echo "Using WPS ${WPS_VERSION}"
}

installWps() {

  apt-get install -y \
      xdg-utils \
      libqt5gui5 \
      libxslt1.1 \
      libqt5core5a \
      libqt5widgets5 \
      libqt5dbus5

  mkdir -p /deployment/software/wps
  cd /deployment/software/wps || exit 1
  wget "$WPS_DEB_URL" -O "wps-office_${WPS_VERSION}_amd64.deb"
  apt-get install -f -y "./wps-office_${WPS_VERSION}_amd64.deb"
  cd /deployment || exit 1
  rm -rf /deployment/software/wps

}

autoExecuteFunc setEnv installWps
