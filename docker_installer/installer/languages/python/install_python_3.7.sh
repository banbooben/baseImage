source /deployment/scripts/common.sh

setEnv(){
  export INSTALL_PATH=/deployment/python
  export PATH=${INSTALL_PATH}/bin:$PATH
  export LANG=C.UTF-8
  export GPG_KEY=7169605F62C751356D054A26A821E680E5FA6305
  export PYTHON_GET_PIP_URL=https://bootstrap.pypa.io/get-pip.py
  export PYTHON_SERIES=3.7
  PYTHON_VERSION="$(resolve_python_latest_version "$PYTHON_SERIES")" || return 1
  export PYTHON_VERSION
  echo "Using Python ${PYTHON_VERSION} (series ${PYTHON_SERIES})"
  write_cont_env PYTHON_VERSION "${PYTHON_VERSION}"
  write_cont_env PYTHON_SERIES "${PYTHON_SERIES}"

}

download_python_package(){

  mkdir -p ${INSTALL_PATH}/install
  cd ${INSTALL_PATH}/install
  apt-get install -y --no-install-recommends libbluetooth-dev tk-dev uuid-dev libssl-dev libsqlite3-dev libffi-dev

  wget -O python.tar.xz "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz" --no-check-certificate
  tar --extract --directory ${INSTALL_PATH}/install --strip-components=1 --file python.tar.xz
  rm python.tar.xz
  gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"
}

make_install(){
  buildArch="$(dpkg --print-architecture)"
  PYTHON_PERF_FLAGS="--enable-optimizations --with-lto"
  if [ "$buildArch" = "arm64" ]; then
    echo "arm64 build detected, disabling PGO/LTO for better build stability"
    PYTHON_PERF_FLAGS=""
  fi

  ./configure \
    --build="$gnuArch" \
    --prefix=${INSTALL_PATH} \
    --enable-loadable-sqlite-extensions \
    --enable-option-checking=fatal \
    --enable-shared \
    $PYTHON_PERF_FLAGS \
    --with-system-expat \
    --with-ensurepip

  nproc="$(nproc)"
  EXTRA_CFLAGS="$(dpkg-buildflags --get CFLAGS)"
  LDFLAGS="$(dpkg-buildflags --get LDFLAGS)"
	make -j "$nproc" \
		"EXTRA_CFLAGS=${EXTRA_CFLAGS:-}" \
		"LDFLAGS=${LDFLAGS:--Wl},-rpath='\$\$ORIGIN/../lib'" \
		"PROFILE_TASK=${PROFILE_TASK:-}" python
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

install_pip(){
  wget -O get-pip.py "$PYTHON_GET_PIP_URL" --no-check-certificate
  export PYTHONDONTWRITEBYTECODE=1
  python3 get-pip.py \
    --disable-pip-version-check \
    --no-cache-dir \
    --no-compile
}

clear_folder(){
  rm -rf ${INSTALL_PATH}/install
}


autoExecuteFunc setEnv download_python_package make_install clear_folder

#
#
#beforeInstall
#installBaseSoft
#setEnv
#executeWithRetry download_python_package 5
#executeWithRetry make_install 5
#executeWithRetry install_pip 5
#clear_folder
#enInstall
