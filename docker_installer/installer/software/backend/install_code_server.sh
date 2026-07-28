#!/bin/bash
source /deployment/scripts/common.sh

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



initConfigFile(){
  mkdir -p /etc/s6-overlay/s6-rc.d/code-server/dependencies.d

  ensure_password CODE_SERVER_PASSWORD
  # 配置文件（变量需展开，故不用引号 EOF）
  cat > /deployment/software/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:8080
auth: password
password: ${CODE_SERVER_PASSWORD}
cert: false
extensions-dir: /deployment/software/code-server/extensions
EOF
  unset CODE_SERVER_PASSWORD

  # 启动脚本
  cat > /etc/s6-overlay/s6-rc.d/code-server/run <<'EOF'
#!/bin/bash
export PATH=/deployment/software/code-server/bin:$PATH

exec /deployment/software/code-server/bin/code-server --config /deployment/software/code-server/config.yaml --extensions-dir /deployment/software/code-server/extensions
EOF

  # 启动类型
  cat > /etc/s6-overlay/s6-rc.d/code-server/type <<'EOF'
longrun
EOF

  # 启动依赖
  cat > /etc/s6-overlay/s6-rc.d/code-server/dependencies.d/base <<'EOF'
EOF

  # 启动配置
  cat > /etc/s6-overlay/s6-rc.d/user/contents.d/code-server <<'EOF'
EOF

  chmod 0755 /etc/s6-overlay/s6-rc.d/code-server/run
  chmod 0644 /etc/s6-overlay/s6-rc.d/code-server/type
  chmod 0644 /etc/s6-overlay/s6-rc.d/code-server/dependencies.d/base

}


installCodeServer(){
  echo "install code server"
  check_target_arch

  VERSION="$(resolve_github_latest_tag coder/code-server CODE_SERVER_PIN_VERSION)" || return 1
  export VERSION
  echo "Using code-server ${VERSION}"
  write_cont_env CODE_SERVER_VERSION "${VERSION}"
  mkdir -p /deployment/software/code-server/lib /deployment/software/code-server/bin /deployment/software/code-server/extensions
  curl -fL https://github.com/coder/code-server/releases/download/v${VERSION}/code-server-${VERSION}-linux-${TARGET_ARCH}.tar.gz \
    | tar -C /deployment/software/code-server/lib -xz
  mv /deployment/software/code-server/lib/code-server-$VERSION-linux-${TARGET_ARCH} /deployment/software/code-server/lib/code-server-$VERSION
  ln -s /deployment/software/code-server/lib/code-server-$VERSION/bin/code-server /deployment/software/code-server/bin/code-server
  PATH="/deployment/software/code-server/bin:$PATH"
#  code-server
  EXTENSIONS=(
    ms-python.python
    cweijan.vscode-mysql-client2
    github.github-vscode-theme
    charliermarsh.ruff
    natizyskunk.sftp
    ms-toolsai.jupyter
  )

  for EXTENSION in "${EXTENSIONS[@]}"; do
    code-server --extensions-dir /deployment/software/code-server/extensions --install-extension "$EXTENSION"
  done

}


autoExecuteFunc installCodeServer initConfigFile
unset CODE_SERVER_PASSWORD
