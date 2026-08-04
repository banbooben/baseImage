source /deployment/scripts/common.sh

setEnv(){
  export INSTALL_PATH=/deployment/software/python
  export PATH=${INSTALL_PATH}/bin:$PATH
  export LANG=C.UTF-8
  export GPG_KEY=7169605F62C751356D054A26A821E680E5FA6305
  export PYTHON_SERIES=3.13
  PYTHON_VERSION="$(resolve_python_latest_version "$PYTHON_SERIES")" || return 1
  export PYTHON_VERSION
  export PYTHON_GET_PIP_URL=https://bootstrap.pypa.io/get-pip.py
  echo "Using Python ${PYTHON_VERSION} (series ${PYTHON_SERIES})"
  write_cont_env PYTHON_VERSION "${PYTHON_VERSION}"
  write_cont_env PYTHON_SERIES "${PYTHON_SERIES}"

}

download_python_package(){

  mkdir -p ${INSTALL_PATH}/install
  cd ${INSTALL_PATH}/install

  wget -O python.tar.xz "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz" --no-check-certificate
  GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
  tar --extract --directory ${INSTALL_PATH}/install --strip-components=1 --file python.tar.xz
  rm python.tar.xz
  gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"
}

make_install(){
  buildArch="$(dpkg --print-architecture)"
  cpuCount="$(nproc)"
  armExtraCflags=""

  # 兼容两套参数名：PYTHON_ENABLE_OPTIMIZATIONS (新) 优先级高于 PYTHON_PERF_FLAGS (旧)
  if [ -n "${PYTHON_PERF_FLAGS+set}" ]; then
    # 旧参数：显式覆盖全部 configure 标志（保持向后兼容）
    local perf_flags="${PYTHON_PERF_FLAGS}"
  elif [ "${PYTHON_ENABLE_OPTIMIZATIONS:-true}" != "false" ]; then
    local perf_flags="--enable-optimizations --with-lto"
  else
    local perf_flags=""
  fi

  if [ "$buildArch" = "arm64" ]; then
    echo "arm64 build detected, disabling PGO/LTO for better build stability"
    perf_flags=""
    makeJobs="${PYTHON_MAKE_JOBS:-1}"
    armExtraCflags="${PYTHON_ARM_EXTRA_CFLAGS:--O2 -fno-strict-aliasing}"
  else
    makeJobs="${PYTHON_MAKE_JOBS:-$cpuCount}"
  fi

  if [ "$makeJobs" -gt "$cpuCount" ]; then
    makeJobs="$cpuCount"
  fi

  ./configure \
    --build="$gnuArch" \
    --prefix=${INSTALL_PATH} \
    --enable-loadable-sqlite-extensions \
    --enable-option-checking=fatal \
    --enable-shared \
    --disable-gil \
    $perf_flags \
    --with-system-expat \
    --with-ensurepip

  EXTRA_CFLAGS="$(dpkg-buildflags --get CFLAGS)"
  LDFLAGS="$(dpkg-buildflags --get LDFLAGS)"
  if ! make -j "$makeJobs" \
    "EXTRA_CFLAGS=${EXTRA_CFLAGS:-} ${armExtraCflags}" \
    "LDFLAGS=${LDFLAGS:--Wl},-rpath='\$\$ORIGIN/../lib'" \
    "PROFILE_TASK=${PROFILE_TASK:-}" python; then
    if [ "$buildArch" = "arm64" ]; then
      echo "arm64 build failed, retrying with single job and safer flags"
      make clean || true
      make -j 1 \
        "EXTRA_CFLAGS=${EXTRA_CFLAGS:-} -O1 -fno-strict-aliasing -fno-tree-vectorize" \
        "LDFLAGS=${LDFLAGS:--Wl},-rpath='\$\$ORIGIN/../lib'" \
        "PROFILE_TASK=${PROFILE_TASK:-}" python
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
}

clear_folder(){
  rm -rf ${INSTALL_PATH}/install
}


autoExecuteFunc setEnv download_python_package make_install clear_folder
