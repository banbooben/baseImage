#!/bin/bash
###
 # Install llama.cpp (CPU-only) under /deployment/software/llama.cpp.
 #
 # Layer layout (COPY-friendly, rpath 用 $ORIGIN，整棵树可整体搬运):
 #   /deployment/software/llama.cpp/bin/         # llama / llama-cli / llama-server / llama-quantize …
 #   /deployment/software/llama.cpp/lib/         # x86_64 共享库（libllama / libggml / libggml-base）
 #   /deployment/bin/llama*                      # 常用命令的启动器符号链接
 #
 # 上游：https://github.com/ggml-org/llama.cpp（源码构建，amd64/arm64 统一）
 #
 # 为什么是 CPU 版：
 #   CUDA / HIP / Vulkan / SYCL 各自要带一整套工具链与运行时（CUDA Toolkit、
 #   ROCm、Vulkan SDK…），镜像体积和构建耗时都会翻倍，而且不同显卡要出不同的
 #   变体镜像。这里先只出 CPU 版，GPU 后端由后续独立镜像（如 llama-cpp-cuda）
 #   按需扩展；本脚本的 cmake 参数已经显式关掉全部 GPU 后端。
 #
 # 两套 CPU 优化策略（按架构分派）：
 #   x86_64  上游发布版同款：GGML_BACKEND_DL + GGML_CPU_ALL_VARIANTS，
 #           一次编出 x64/sse42/haswell/skylakex/…/sapphirerapids 等多个
 #           ggml-cpu-*.so，运行时按 CPU 特性挑最优的一个。既保留 AVX2/AVX512
 #           性能，又不会在老 CPU 上 SIGILL。
 #   arm64   只编一个 armv8-a 基线版本：ARM 变体要重复编译 8 遍，而 CI 的
 #           多架构构建走 QEMU 模拟，耗时是 native 的数倍，不划算。
 #
 # 构建期可覆盖（Dockerfile build-arg）：
 #   LLAMACPP_PIN_VERSION  钉死版本（如 0.8.0 或 v0.8.0），默认取 latest release
###
source /deployment/scripts/common.sh

check_target_arch(){
  ARCH=$(uname -m)
  case $ARCH in
      x86_64|amd64)
          TARGET_ARCH="x86_64"
          ;;
      aarch64|arm64)
          TARGET_ARCH="aarch64"
          ;;
      *)
          echo "未知架构: $ARCH"
          exit 1
          ;;
  esac
  export TARGET_ARCH
  echo "目标架构: ${TARGET_ARCH}"
}

setEnv(){
  check_target_arch
  export DEBIAN_FRONTEND=noninteractive
  export INSTALL_PATH=/deployment/software/llama.cpp
  export SOURCE_DIR=/tmp/llama.cpp-src
  export BUILD_DIR=/tmp/llama.cpp-build

  # resolve_github_latest_tag 会把 tag 的 v 前缀去掉（v0.8.0 → 0.8.0），
  # 下载时再把 v 前缀补回去试（见 download_source）
  LLAMACPP_VERSION="$(resolve_github_latest_tag ggml-org/llama.cpp LLAMACPP_PIN_VERSION)" || return 1
  export LLAMACPP_VERSION
  echo "Using llama.cpp ${LLAMACPP_VERSION} (${TARGET_ARCH})"
}

installDeps(){
  # base 已含 build-essential（gcc/g++/make）、git、curl、libssl-dev；
  # 这里只补 llama.cpp 构建缺的 cmake。cmake 在 Ubuntu / openEuler 同名，无需映射。
  pkg_update || return 1
  pkg_install cmake || return 1
  pkg_clean
}

downloadSource(){
  local archive="/tmp/llama.cpp-${LLAMACPP_VERSION}.tar.gz"
  local ref url

  rm -f "${archive}"
  # latest release 的 tag 形如 v0.8.0（带 v），nightly 的 tag 形如 b12099（不带 v）；
  # pin 进来时用户也可能带或不带 v。两个候选都试，命中即停。
  for ref in "v${LLAMACPP_VERSION}" "${LLAMACPP_VERSION}"; do
    url="https://github.com/ggml-org/llama.cpp/archive/refs/tags/${ref}.tar.gz"
    echo "Downloading ${url}"
    if curl -fL --connect-timeout 30 --max-time 600 -o "${archive}" "${url}"; then
      SOURCE_ARCHIVE="${archive}"
      echo "使用源码 tag: ${ref}"
      export SOURCE_ARCHIVE
      return 0
    fi
    rm -f "${archive}"
  done

  echo "Failed to download llama.cpp ${LLAMACPP_VERSION}" >&2
  return 1
}

installLlamaCpp(){
  downloadSource || return 1

  # 失败重试时把上一次的半成品清干净，避免残留文件混进最终镜像
  rm -rf "${SOURCE_DIR}" "${BUILD_DIR}" "${INSTALL_PATH}"
  mkdir -p "${SOURCE_DIR}" "${BUILD_DIR}" "${INSTALL_PATH}" /deployment/bin

  # GitHub 的归档目录名是 llama.cpp-<tag>，--strip-components=1 去掉这一层
  tar -xzf "${SOURCE_ARCHIVE}" -C "${SOURCE_DIR}" --strip-components=1 || return 1
  rm -f "${SOURCE_ARCHIVE}"

  # 通用参数：
  #   GGML_NATIVE=OFF  绝不能用 -march=native：CI 上编出来的指令集必须能在目标机跑
  #   全部 GPU 后端显式关掉，保证 CPU-only 且不因宿主装了 CUDA/Vulkan 意外链接
  #   测试/示例不装，只装命令行工具和统一入口 llama
  #   CMAKE_INSTALL_LIBDIR=lib   RPM 系（openEuler）GNUInstallDirs 默认用 lib64，
  #   与下面 $ORIGIN/../lib 的 RPATH 对不上，llama-cli 会找不到 libllama-*-impl.so；
  #   两个发行版统一装 lib/，层布局与 COPY-friendly 说明保持一致
  local -a cmake_args=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PATH}"
    -DCMAKE_INSTALL_LIBDIR=lib
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TOOLS=ON
    -DLLAMA_BUILD_SERVER=ON
    -DLLAMA_BUILD_APP=ON
    -DLLAMA_TOOLS_INSTALL=ON
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=ON
    -DGGML_BLAS=OFF
    -DGGML_CUDA=OFF
    -DGGML_HIP=OFF
    -DGGML_VULKAN=OFF
    -DGGML_SYCL=OFF
    -DGGML_OPENCL=OFF
    -DGGML_METAL=OFF
    -DGGML_WEBGPU=OFF
    -DGGML_RPC=OFF
  )

  if [ "${TARGET_ARCH}" = "x86_64" ]; then
    # 运行时按 CPU 特性选 ggml-cpu-<variant>.so（见文件头说明）。
    # $ORIGIN/$ORIGIN/../lib 让 lib/ 下的 .so 与 bin/ 下的可执行文件互相找得到，
    # 整层 COPY 到别的镜像也能直接跑；lib64 只是兜底（个别上游布局会用）。
    cmake_args+=(
      -DBUILD_SHARED_LIBS=ON
      -DGGML_BACKEND_DL=ON
      -DGGML_CPU_ALL_VARIANTS=ON
      -DCMAKE_INSTALL_RPATH='$ORIGIN;$ORIGIN/../lib;$ORIGIN/../lib64'
    )
  else
    # ARM 单变体静态构建：产物不依赖 /deployment 下的 .so，最省心
    cmake_args+=(-DBUILD_SHARED_LIBS=OFF)
  fi

  echo "Configuring llama.cpp …"
  cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" "${cmake_args[@]}" || return 1

  echo "Building llama.cpp (jobs=$(nproc)) …"
  cmake --build "${BUILD_DIR}" -j"$(nproc)" || return 1

  cmake --install "${BUILD_DIR}" || return 1

  # 构建目录里是整份源码 + 中间产物（GB 级），必须清掉，否则进镜像
  rm -rf "${SOURCE_DIR}" "${BUILD_DIR}"

  if [ ! -x "${INSTALL_PATH}/bin/llama-server" ] || [ ! -x "${INSTALL_PATH}/bin/llama-cli" ]; then
    echo "llama-server / llama-cli 未生成，安装失败" >&2
    ls -la "${INSTALL_PATH}/bin" >&2 || true
    return 1
  fi
}

initConfig(){
  # 常用命令挂到 /deployment/bin，和 claude/docker 等层保持一致的调用方式
  local bin
  for bin in llama llama-cli llama-server llama-quantize llama-bench; do
    [ -x "${INSTALL_PATH}/bin/${bin}" ] && ln -sfn "${INSTALL_PATH}/bin/${bin}" "/deployment/bin/${bin}"
  done

  # 冒烟测试：能启动并打印版本/用法即可（不加载模型）
  "${INSTALL_PATH}/bin/llama-cli" --version 2>&1 | head -n 2 || true

  write_cont_env LLAMACPP_VERSION "${LLAMACPP_VERSION}"
  write_cont_env LLAMACPP_HOME "${INSTALL_PATH}"

  # 持久化给 merge_and_save_env / 子镜像。
  # 注意不要在这里写 PATH=$PATH 之类的行：/etc/environment 由 PAM 解析，不做
  # shell 展开，字面量 "$PATH" 会原样成为 PATH 的值，把 SSH / su - 登录会话的
  # 系统路径（/usr/bin 等）整个冲掉。PATH 交给 Dockerfile ENV 与 profile.d。
  {
    echo "export LLAMACPP_HOME=${INSTALL_PATH}"
    echo "export LLAMACPP_VERSION=${LLAMACPP_VERSION}"
  } >> /etc/environment

  # Dockerfile 的 ENV 只对容器主进程生效，SSH / su - / bash -l 这类登录 shell
  # 不读镜像 Config.Env（s6 的 /init <cmd> 也会把它清掉）。profile.d 里再补一份，
  # 保证交互会话里 llama-* 能直接调用；已在 PATH 里则不重复追加。
  cat > /etc/profile.d/llama-cpp.sh <<EOF
export LLAMACPP_HOME=${INSTALL_PATH}
export LLAMACPP_VERSION=${LLAMACPP_VERSION}
case ":\${PATH}:" in
  *:${INSTALL_PATH}/bin:*) ;;
  *) export PATH=${INSTALL_PATH}/bin:/deployment/bin:\${PATH} ;;
esac
EOF

  cat > "${INSTALL_PATH}/README.md" <<EOF
# llama.cpp layer (CPU-only)

Built from source (\`ggml-org/llama.cpp\` ${LLAMACPP_VERSION}) at \`${INSTALL_PATH}\`.

- x86_64: runtime CPU dispatch via \`ggml-cpu-*.so\` (\`GGML_CPU_ALL_VARIANTS\`),
  so the same image works from SSE4.2 up to AVX512/AMX machines.
- aarch64: single armv8-a baseline build.
- GPU backends (CUDA / HIP / Vulkan / SYCL / OpenCL) are disabled in this image.

\`\`\`bash
# 命令行交互
llama-cli -m /deployment/data/models/model.gguf -p "Hello"

# OpenAI 兼容服务（默认 8080，端点和参数见 --help）
llama-server -m /deployment/data/models/model.gguf --host 0.0.0.0 --port 8081

# 量化
llama-quantize model-f16.gguf model-q4_k_m.gguf Q4_K_M
\`\`\`

模型文件不要打进镜像：挂载 \`/deployment/data/models\` 或运行时下载。

COPY-friendly 片段：

\`\`\`dockerfile
COPY --from=<llama-cpp-image> ${INSTALL_PATH} ${INSTALL_PATH}
COPY --from=<llama-cpp-image> /etc/cont-env.d/LLAMACPP_VERSION /etc/cont-env.d/LLAMACPP_VERSION
COPY --from=<llama-cpp-image> /etc/cont-env.d/LLAMACPP_HOME /etc/cont-env.d/LLAMACPP_HOME
COPY --from=<llama-cpp-image> /etc/profile.d/llama-cpp.sh /etc/profile.d/llama-cpp.sh
\`\`\`
EOF

  chown -R sarmn:sarmn "${INSTALL_PATH}"
}

autoExecuteFunc setEnv installDeps installLlamaCpp initConfig
