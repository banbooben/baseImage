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

  # 镜像不写密码：code-server 原生支持运行期环境变量 PASSWORD / HASHED_PASSWORD。
  # 启动时若不提供，code-server 会报错退出（不会生成默认密码），避免无意中
  # 以弱口令或无认证对外暴露。运行示例：
  #   docker run -e PASSWORD='...' ...
  cat > /deployment/software/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:8080
auth: password
cert: false
extensions-dir: /deployment/software/code-server/extensions
EOF

  # 启动脚本
  # 必须用 with-contenv：s6-rc 的 longrun 服务不继承容器环境，普通 #!/bin/bash
  # 读不到 -e 注入的 PASSWORD，code-server 会因无密码反复退出。
  # 以 sam 运行：否则在 workspace 里新建的文件都是 root 所有，桌面里的 sam
  # 改不了；HOME 也要显式给，s6-setuidgid 不会改 HOME，继承下来的 /root 会让
  # code-server 写不了自己的 user-data-dir。
  cat > /etc/s6-overlay/s6-rc.d/code-server/run <<'EOF'
#!/command/with-contenv bash
export PATH=/deployment/software/code-server/bin:$PATH
export HOME=/deployment/accounts/sam

exec s6-setuidgid sam /deployment/software/code-server/bin/code-server --config /deployment/software/code-server/config.yaml --extensions-dir /deployment/software/code-server/extensions
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

  # 运行期以 sam 跑 code-server（见 initConfigFile 的 run 脚本）：整个安装目录
  # 归 sam 所有，运行时装/删扩展才有权限。PUID 改变后 05-puid-pgid 会再 chown 一次。
  chown -R sam:sam /deployment/software/code-server

}


autoExecuteFunc installCodeServer initConfigFile
