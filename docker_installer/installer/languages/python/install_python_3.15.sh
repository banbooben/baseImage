source /deployment/scripts/common.sh

setEnv(){
  export INSTALL_PATH=/deployment/software/python
  export PATH=${INSTALL_PATH}/bin:$PATH
  export LANG=C.UTF-8
  export PYTHON_SERIES=3.15
  PYTHON_VERSION="$(resolve_python_latest_version "$PYTHON_SERIES")" || return 1
  export PYTHON_VERSION
  echo "Using Python ${PYTHON_VERSION} (series ${PYTHON_SERIES})"
  write_cont_env PYTHON_VERSION "${PYTHON_VERSION}"
  write_cont_env PYTHON_SERIES "${PYTHON_SERIES}"

}

download_python_package(){

  mkdir -p ${INSTALL_PATH}/install
  cd ${INSTALL_PATH}/install || return 1

  # 预发布 tar 包也放在基础版本目录里（3.15.0/Python-3.15.0rc2.tar.xz），
  # 故目录名剥离 a/b/rc 后缀；wget/tar 失败必须返回非 0，
  # 否则 404 页面流入后续 ./configure 产生无效重试
  wget -O python.tar.xz "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz" --no-check-certificate || return 1
  GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
  tar --extract --directory ${INSTALL_PATH}/install --strip-components=1 --file python.tar.xz || return 1
  rm python.tar.xz
  gnuArch="$(build_triplet)"
}

make_install(){
  buildArch="$(deb_arch)"
  cpuCount="$(nproc)"
  armExtraCflags=""
  configure_args=(
    "--build=$gnuArch"
    "--prefix=${INSTALL_PATH}"
    "--enable-loadable-sqlite-extensions"
    "--enable-option-checking=fatal"
    "--enable-shared"
    "--with-system-expat"
    "--with-ensurepip"
  )

  if [ "$buildArch" = "arm64" ]; then
    echo "arm64 build detected, disabling PGO/LTO for better build stability"
    makeJobs="${PYTHON_MAKE_JOBS:-1}"
    armExtraCflags="${PYTHON_ARM_EXTRA_CFLAGS:--O2 -fno-strict-aliasing}"
  else
    if [ "${PYTHON_ENABLE_OPTIMIZATIONS:-true}" != "false" ]; then
      configure_args+=("--enable-optimizations" "--with-lto")
    fi
    makeJobs="${PYTHON_MAKE_JOBS:-$cpuCount}"
  fi

  if [ "$makeJobs" -gt "$cpuCount" ]; then
    makeJobs="$cpuCount"
  fi

  ./configure "${configure_args[@]}"

  EXTRA_CFLAGS="$(build_cflags)"
  LDFLAGS="$(build_ldflags)"
  if ! make -j "$makeJobs" \
    "EXTRA_CFLAGS=${EXTRA_CFLAGS:-} ${armExtraCflags}" \
    "LDFLAGS=${LDFLAGS:--Wl},-rpath='\$\$ORIGIN/../lib'" \
    "PROFILE_TASK=${PROFILE_TASK:-}"; then
    if [ "$buildArch" = "arm64" ]; then
      echo "arm64 build failed, retrying with single job and safer flags"
      make clean || true
      make -j 1 \
    "EXTRA_CFLAGS=${EXTRA_CFLAGS:-} -O1 -fno-strict-aliasing -fno-tree-vectorize" \
    "LDFLAGS=${LDFLAGS:--Wl},-rpath='\$\$ORIGIN/../lib'" \
    "PROFILE_TASK=${PROFILE_TASK:-}"
    else
      return 1
    fi
  fi
	make install

  find ${INSTALL_PATH}/install -depth \
    \( \
      \( -type d -a \( -name test -o -name tests -o -name idle_test \) \) \
      -o \( -type f -a \( -name '*.pyc' -o -name '*.pyo' -o -name 'libpython*.a' \) \) \
    \) -exec rm -rf '{}' + \
  ; \
  \
  ldconfig
  [ -n "$GNUPGHOME" ] && rm -rf "$GNUPGHOME"
}

clear_folder(){
  rm -rf ${INSTALL_PATH}/install
}


autoExecuteFunc setEnv download_python_package make_install clear_folder
