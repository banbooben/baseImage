#!/bin/bash
source /deployment/scripts/common.sh

# llama.cpp CUDA 版（builder 阶段执行）：
#   - NVIDIA 官方 apt 仓库安装 CUDA toolkit（编译期）；
#   - 最终镜像只需 cuda-cudart/libcublas 运行时（见 Dockerfile 最终 stage）；
#   - 内核驱动在宿主机，容器经 nvidia-container-toolkit（--gpus all）使用 GPU。
#
# 可调环境变量：
#   LLAMACPP_PIN_VERSION   固定版本（如 b10690），默认解析发布列表第一条
#                          （注意：/releases/latest 指向旧版 v0.3.0，不可用）
#   CUDA_SERIES            CUDA 版本系列，默认 12-8（需宿主机驱动 >= 525）
#   CUDA_ARCHITECTURES     编译的目标 SM 架构，分号分隔

setEnv(){
  export BASE_PATH=/deployment
  export INSTALL_PATH=/deployment/software/llamacpp
  export LANG=C.UTF-8
  export CUDA_SERIES="${CUDA_SERIES:-12-8}"
  export CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES:-75;80;86;89;90;100;120}"
  LLAMACPP_VERSION="$(resolve_llamacpp_latest_version)" || return 1
  export LLAMACPP_VERSION
  echo "Using llama.cpp ${LLAMACPP_VERSION} (CUDA ${CUDA_SERIES}, SM: ${CUDA_ARCHITECTURES})"
}

# llama.cpp 的 /releases/latest 标记在旧版 v0.3.0 上，须取发布列表第一条
resolve_llamacpp_latest_version(){
  if [ -n "${LLAMACPP_PIN_VERSION:-}" ]; then
    echo "$LLAMACPP_PIN_VERSION"
    return 0
  fi

  local latest=""
  latest="$(_installer_http_get "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=1" 2>/dev/null \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1)"

  if [ -z "$latest" ]; then
    echo "Failed to resolve latest llama.cpp version" >&2
    return 1
  fi

  echo "$latest"
}

install_cuda_repo(){
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/3bf863cc.pub \
    | gpg --dearmor -o /etc/apt/keyrings/cuda.gpg
  chmod a+r /etc/apt/keyrings/cuda.gpg
  echo "deb [signed-by=/etc/apt/keyrings/cuda.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /" \
    > /etc/apt/sources.list.d/cuda.list
  apt-get update
}

install_build_deps(){
  # cuda-driver-dev 提供 libcuda.so stub（无 GPU 的构建机上链接用）
  apt-get install -y --no-install-recommends \
    cmake ninja-build git libcurl4-openssl-dev \
    cuda-nvcc-${CUDA_SERIES} \
    cuda-cudart-dev-${CUDA_SERIES} \
    libcublas-dev-${CUDA_SERIES} \
    cuda-driver-dev-${CUDA_SERIES}

  # nvcc 装在 /usr/local/cuda/bin，不在默认 PATH；显式导出供 cmake 定位 CUDA 编译器
  export PATH=/usr/local/cuda/bin:$PATH
  export CUDACXX=/usr/local/cuda/bin/nvcc
  nvcc --version || return 1

  # 无 GPU 构建机靠 libcuda.so stub 链接，但 stub 目录只有 libcuda.so、
  # 没有 SONAME 对应的 libcuda.so.1，链接可执行文件时会报 undefined reference
  # （运行时由 nvidia-container-toolkit 挂载宿主机真实驱动库，不受影响）
  local stubs=/usr/local/cuda/targets/x86_64-linux/lib/stubs
  if [ -f ${stubs}/libcuda.so ] && [ ! -e ${stubs}/libcuda.so.1 ]; then
    ln -sf libcuda.so ${stubs}/libcuda.so.1
  fi
}

build_llamacpp(){
  # 注意：本脚本由 RUN 以子 bash 执行，不继承外层 set -e；
  # 且 executeWithRetry 只看函数返回码，关键命令必须显式 || return 1，
  # 否则 cmake 失败后脚本继续走、ln -sf 对缺失文件也会"成功"，导致空镜像
  mkdir -p ${BASE_PATH}/bin ${INSTALL_PATH}/install
  cd ${INSTALL_PATH}/install || return 1

  LLAMACPP_DOWNLOAD_URL=https://github.com/ggml-org/llama.cpp/archive/refs/tags/${LLAMACPP_VERSION}.tar.gz
  wget -O llama.cpp.tar.gz ${LLAMACPP_DOWNLOAD_URL} --no-check-certificate || return 1
  tar -xvf llama.cpp.tar.gz || return 1
  # tar 解压目录会去掉 tag 前导 v（v0.4.0 → llama.cpp-0.4.0；b10797 不变）
  cd llama.cpp-${LLAMACPP_VERSION#v} || return 1

  # GGML_NATIVE=OFF：避免按构建机 CPU 特性（-march=native）生成不可移植代码
  # LLAMA_CURL 已弃用：新版 llama.cpp 自动探测 libcurl，无需显式开关
  # TESTS/EXAMPLES=OFF：测试目标不纳入默认构建但带安装规则，会导致
  #   cmake --install 找不到 test-* 二进制而失败；生产镜像也不需要它们
  cmake -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=OFF \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PATH} || return 1
  cmake --build build -j$(nproc) || return 1
  cmake --install build || return 1

  # 产物校验：二进制缺失即失败，让 executeWithRetry 重试/终止
  if [ ! -x ${INSTALL_PATH}/bin/llama-server ] || [ ! -x ${INSTALL_PATH}/bin/llama-cli ]; then
    echo "llama.cpp 构建产物缺失: ${INSTALL_PATH}/bin" >&2
    return 1
  fi

  ln -sf ${INSTALL_PATH}/bin/llama-server ${BASE_PATH}/bin/llama-server
  ln -sf ${INSTALL_PATH}/bin/llama-cli ${BASE_PATH}/bin/llama-cli
}

init_start_script(){
  mkdir -p /deployment/workspace/apps/models
  cat > ${INSTALL_PATH}/start.sh <<'EOF'
#!/bin/bash
# llama-server 手动启动脚本（不注册 s6 服务，由用户自行启动）
# 模型不烤进镜像：挂载到 /deployment/workspace/apps/models 或用 LLAMA_MODEL 指定路径
MODEL="${LLAMA_MODEL:-/deployment/workspace/apps/models/model.gguf}"
HOST="${LLAMA_HOST:-0.0.0.0}"
PORT="${LLAMA_PORT:-8000}"
NGL="${N_GPU_LAYERS:-999}"

if [ ! -f "$MODEL" ]; then
  echo "[llamacpp] 模型文件不存在: $MODEL"
  echo "[llamacpp] 请挂载模型（-v /path/models:/deployment/workspace/apps/models）或设置 LLAMA_MODEL 后重试"
  exit 1
fi

exec /deployment/software/llamacpp/bin/llama-server \
  --model "$MODEL" \
  --host "$HOST" \
  --port "$PORT" \
  --n-gpu-layers "$NGL" \
  ${LLAMA_EXTRA_ARGS:-}
EOF
  chmod 0755 ${INSTALL_PATH}/start.sh
}

clear_folder(){
  rm -rf ${INSTALL_PATH}/install
}

autoExecuteFunc setEnv install_cuda_repo install_build_deps build_llamacpp init_start_script clear_folder
