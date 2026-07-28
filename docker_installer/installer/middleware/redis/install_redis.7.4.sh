source /deployment/scripts/common.sh

setEnv(){
  export BASE_PATH=/deployment
  export INSTALL_PATH=/deployment/software/redis
  export LANG=C.UTF-8
  export REDIS_SERIES=7.4
  REDIS_VERSION="$(resolve_eol_latest_version redis "$REDIS_SERIES" REDIS_PIN_VERSION)" || return 1
  export REDIS_VERSION
  echo "Using Redis ${REDIS_VERSION} (series ${REDIS_SERIES})"

}

init_config(){
  ensure_password REDIS_PASSWORD
echo "
daemonize no
requirepass ${REDIS_PASSWORD}
bind 0.0.0.0
appendonly yes

# port 6379

pidfile ${INSTALL_PATH}/redis-server.pid

dir ${INSTALL_PATH}/data

" > ${INSTALL_PATH}/redis.conf
  unset REDIS_PASSWORD

echo '
#!/bin/bash

# Check if the Redis configuration file exists
if [ ! -f "/deployment/software/redis/redis.conf" ]; then
  echo "Redis configuration file not found: /deployment/software/redis/redis.conf"
  exit 1
fi

# Check if Redis is already running
if pgrep -x "redis-server" > /dev/null; then
  echo "Redis server is already running."
  exit 0
fi

# Start the Redis server
echo "Starting Redis server..."
redis-server /deployment/software/redis/redis.conf
' > ${INSTALL_PATH}/start.sh

}


download_python_package(){

    mkdir -p ${BASE_PATH}/bin ${INSTALL_PATH}/install ${INSTALL_PATH}/data
    cd ${INSTALL_PATH}/install

    REDIS_DOWNLOAD_URL=https://github.com/redis/redis/archive/refs/tags/${REDIS_VERSION}.tar.gz
    wget -O redis.tar.gz ${REDIS_DOWNLOAD_URL} --no-check-certificate
    tar -xvf redis.tar.gz
    cd redis-${REDIS_VERSION}
    gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"
    dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"
    dpkgArch="$(dpkg --print-architecture)"
    extraJemallocConfigureFlags="--build=$gnuArch"
    case "${dpkgArch##*-}" in \
      amd64 | i386 | x32) extraJemallocConfigureFlags="$extraJemallocConfigureFlags --with-lg-page=12" ;; \
      *) extraJemallocConfigureFlags="$extraJemallocConfigureFlags --with-lg-page=16" ;; \
    esac; \
    extraJemallocConfigureFlags="$extraJemallocConfigureFlags --with-lg-hugepage=21"
    grep -F 'cd jemalloc && ./configure ' $INSTALL_PATH/install/redis-${REDIS_VERSION}/deps/Makefile
    sed -ri 's!cd jemalloc && ./configure !&'"$extraJemallocConfigureFlags"' !' $INSTALL_PATH/install/redis-${REDIS_VERSION}/deps/Makefile
    grep -F "cd jemalloc && ./configure $extraJemallocConfigureFlags " $INSTALL_PATH/install/redis-${REDIS_VERSION}/deps/Makefile
    export BUILD_TLS=yes
    make -C $INSTALL_PATH/install/redis-${REDIS_VERSION} -j "$(nproc)" all
    make -C $INSTALL_PATH/install/redis-${REDIS_VERSION} install PREFIX=$INSTALL_PATH

    ln -s $INSTALL_PATH/bin/redis-server ${BASE_PATH}/bin/redis-server
    ln -s $INSTALL_PATH/bin/redis-cli ${BASE_PATH}/bin/redis-cli

    init_config

}

clear_folder(){
  rm -rf ${INSTALL_PATH}/install
}

initS6Config(){
  write_cont_env REDIS_VERSION "${REDIS_VERSION}"
  write_cont_env REDIS_SERIES "${REDIS_SERIES}"
  register_s6_longrun_cmd redis "exec /bin/bash ${INSTALL_PATH}/start.sh"
}

autoExecuteFunc setEnv download_python_package clear_folder initS6Config
unset REDIS_PASSWORD
