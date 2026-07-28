source /deployment/scripts/common.sh

setEnv(){
  export INSTALL_PATH=/deployment/python
  export PATH=${INSTALL_PATH}/bin:$PATH
  export LANG=C.UTF-8
  export GPG_KEY=E3FF2839C048B25C084DEBE9B26995E310250568
  export PYTHON_SERIES=3.9
  PYTHON_VERSION="$(resolve_python_latest_version "$PYTHON_SERIES")" || return 1
  export PYTHON_VERSION
  export PYTHON_PIP_VERSION=23.2.1
  export PYTHON_SETUPTOOLS_VERSION=65.5.1
  export PYTHON_GET_PIP_URL=https://github.com/pypa/get-pip/raw/9af82b715db434abb94a0a6f3569f43e72157346/public/get-pip.py
  export PYTHON_GET_PIP_SHA256=45a2bb8bf2bb5eff16fdd00faef6f29731831c7c59bd9fc2bf1f3bed511ff1fe
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
    --without-ensurepip

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
  echo "$PYTHON_GET_PIP_SHA256 *get-pip.py" | sha256sum -c -
  export PYTHONDONTWRITEBYTECODE=1
  python3 get-pip.py \
    --disable-pip-version-check \
    --no-cache-dir \
    --no-compile \
    "pip==$PYTHON_PIP_VERSION" \
    "setuptools==$PYTHON_SETUPTOOLS_VERSION"
}

clear_folder(){
  rm -rf ${INSTALL_PATH}/install
}


autoExecuteFunc setEnv download_python_package make_install install_pip clear_folder

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
