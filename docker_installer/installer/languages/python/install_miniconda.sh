
setEnv(){
  export INSTALL_PATH=/deployment/miniconda
  export PATH=${INSTALL_PATH}/bin:$PATH
  export LANG=C.UTF-8
  write_cont_env MINICONDA_VERSION "latest"

}

download_and_install(){
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64)
      installer="Miniconda3-latest-Linux-x86_64.sh"
      ;;
    arm64)
      installer="Miniconda3-latest-Linux-aarch64.sh"
      ;;
    *)
      echo "Unsupported architecture for miniconda: $arch"
      exit 1
      ;;
  esac

  mkdir -p ~/miniconda3
  wget "https://repo.anaconda.com/miniconda/${installer}" -O ~/miniconda3/miniconda.sh
  bash ~/miniconda3/miniconda.sh -b -u -p ${INSTALL_PATH}
  rm -rf ~/miniconda3/
}

source /deployment/scripts/common.sh
autoExecuteFunc setEnv download_and_install
