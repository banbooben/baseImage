#!/bin/bash
source /deployment/scripts/common.sh

# OpenResty 官方 apt 仓库仅发布 amd64 deb（无 arm64），
# 为同时支持 linux/amd64 与 linux/arm64，采用源码编译（参照 redis 写法）。

setEnv(){
  export BASE_PATH=/deployment
  export INSTALL_PATH=/deployment/software/openresty
  export LANG=C.UTF-8
  OPENRESTY_VERSION="$(resolve_github_latest_tag openresty/openresty OPENRESTY_PIN_VERSION)" || return 1
  export OPENRESTY_VERSION
  echo "Using OpenResty ${OPENRESTY_VERSION}"
}

install_openresty(){
  # base 镜像已含 build-essential/libssl-dev/zlib1g-dev，仅补 PCRE2 与 perl
  apt-get update
  apt-get install -y --no-install-recommends libpcre2-dev perl

  mkdir -p ${BASE_PATH}/bin ${INSTALL_PATH}/install
  cd ${INSTALL_PATH}/install

  OPENRESTY_DOWNLOAD_URL=https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz
  wget -O openresty.tar.gz ${OPENRESTY_DOWNLOAD_URL} --no-check-certificate
  tar -xvf openresty.tar.gz
  cd openresty-${OPENRESTY_VERSION}

  # --prefix=${INSTALL_PATH}：nginx 实际位于 ${INSTALL_PATH}/nginx
  ./configure \
    --prefix=${INSTALL_PATH} \
    --with-cc-opt='-O2' \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_stub_status_module \
    --with-http_gzip_static_module \
    --with-stream \
    --with-stream_ssl_module \
    --with-pcre-jit \
    -j$(nproc)
  make -j$(nproc)
  make install

  ln -sf ${INSTALL_PATH}/bin/openresty ${BASE_PATH}/bin/openresty
  ln -sf ${INSTALL_PATH}/bin/resty ${BASE_PATH}/bin/resty
}

clear_folder(){
  rm -rf ${INSTALL_PATH}/install
}

initS6Config(){
  write_cont_env OPENRESTY_VERSION "${OPENRESTY_VERSION}"
  register_s6_longrun_cmd openresty "exec ${INSTALL_PATH}/bin/openresty -g 'daemon off;'"
}

autoExecuteFunc setEnv install_openresty clear_folder initS6Config
