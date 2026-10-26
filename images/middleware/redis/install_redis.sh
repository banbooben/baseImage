source /deployment/scripts/common.sh

setEnv(){
  export BASE_PATH=/deployment
  export INSTALL_PATH=/deployment/software/redis
  export LANG=C.UTF-8
  export REDIS_SERIES="${REDIS_SERIES:?REDIS_SERIES is required (e.g. 7.4)}"
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

}


download_redis_package(){

    mkdir -p ${BASE_PATH}/bin ${INSTALL_PATH}/install ${INSTALL_PATH}/data
    cd ${INSTALL_PATH}/install

    REDIS_DOWNLOAD_URL=https://github.com/redis/redis/archive/refs/tags/${REDIS_VERSION}.tar.gz
    wget -O redis.tar.gz ${REDIS_DOWNLOAD_URL} --no-check-certificate
    tar -xvf redis.tar.gz
    cd redis-${REDIS_VERSION}
    gnuArch="$(build_triplet)"
    targetArch="$(deb_arch)"
    extraJemallocConfigureFlags="--build=$gnuArch"
    case "${targetArch##*-}" in \
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

  # 数据域整目录收归 sarmn：bake 时是 root 装的，运行期 redis-server 以 sarmn 跑
  chown -R sarmn:sarmn "${INSTALL_PATH}" || return 1

  # ── s6 longrun 的 run body ────────────────────────────────────────────
  # run body 以 root 启动（register_s6_longrun_cmd 不传 run_user），先在 root 态完成
  # 属主修正，再 setuidgid 切到 sarmn 前台常驻 redis-server；重启语义交给 s6。
  # PUID/PGID 的 uid/gid 对齐由 base 层 /etc/cont-init.d/05-puid-pgid 在服务启动前
  # 统一完成，此处不再重复。run body 落在 /deployment/bin（挂载点 INSTALL_PATH
  # 之外），避免整目录挂卷时被遮蔽（与 dingtalk-dsh 同一范式）。
  cat > /deployment/bin/redis-start.sh <<'EOF'
#!/bin/bash
set -e

RUN_USER="sarmn"

mkdir -p /deployment/software/redis/data
# 重 chown 数据域：PUID/PGID 改过 sarmn 的 uid/gid 后，bake 进去的旧属主文件
# 新 sarmn 读写不了；挂卷场景同样覆盖（cont-init 的 05-puid-pgid 只管 home）。
chown -R "${RUN_USER}:${RUN_USER}" /deployment/software/redis 2>/dev/null || true

# 配置文件自检：整目录挂卷会遮蔽 bake 进去的 conf，提前给出明确报错
if [ ! -f /deployment/software/redis/redis.conf ]; then
  echo "[redis] 配置文件不存在: /deployment/software/redis/redis.conf" >&2
  exit 1
fi

# 已有 redis-server 在跑（如手动起过）则不重复启动，避免抢占端口/pidfile
if pgrep -x "redis-server" > /dev/null; then
  echo "[redis] redis-server 已在运行，跳过重复启动"
  exit 0
fi

# 切到运行用户 sarmn 前台常驻 redis-server（daemonize no，s6 直接监管进程）
echo "[redis] 以 ${RUN_USER} 启动 redis-server..."
exec s6-setuidgid "${RUN_USER}" redis-server /deployment/software/redis/redis.conf
EOF
  chmod 0755 /deployment/bin/redis-start.sh

  # 注册常驻服务：run body 以 root 起，属主修正后 setuidgid 切到 sarmn 常驻
  register_s6_longrun_cmd redis "exec /bin/bash /deployment/bin/redis-start.sh"
}

autoExecuteFunc setEnv download_redis_package clear_folder initS6Config
unset REDIS_PASSWORD
