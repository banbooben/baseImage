# Deployment — 场景化开发镜像

在分层镜像基础上，组合多个软件为**开箱即用**的场景镜像。Dockerfile 位于 `deployment/noble/` 下，构建上下文为仓库根目录。

## 镜像列表

### 桌面开发环境

基于 `base:noble-desktop`，含 Xfce 桌面 + VNC/noVNC + 中文输入法。

| 镜像 | 包含组件 |
| --- | --- |
| [desktop/python-extension-pack/py-3.12-codeserver-sshd-chrome-dbeaver-wps-vscode](noble/desktop/python-extension-pack/py-3.12-codeserver-sshd-chrome-dbeaver-wps-vscode) | Python 3.12 + code-server + SSH + Chrome + DBeaver + WPS + VS Code |
| [desktop/python-extension-pack/py-3.14-codeserver-sshd-chrome-dbeaver-wps-vscode](noble/desktop/python-extension-pack/py-3.14-codeserver-sshd-chrome-dbeaver-wps-vscode) | Python 3.14 + code-server + SSH + Chrome + DBeaver + WPS + VS Code |

### 服务器开发环境

基于 `base:noble`，纯命令行环境。

| 镜像 | 包含组件 |
| --- | --- |
| [server/python-extension-pack/py-3.12-codeserver-sshd](noble/server/python-extension-pack/py-3.12-codeserver-sshd) | Python 3.12 + code-server + SSH |
| [server/python-extension-pack/py-3.14-codeserver-sshd](noble/server/python-extension-pack/py-3.14-codeserver-sshd) | Python 3.14 + code-server + SSH |
| [server/nginx-code/openresty-nginx](noble/server/nginx-code/openresty-nginx) | OpenResty + code-server |

### GPU 推理环境

基于 `base:noble`，含 NVIDIA 官方源 CUDA 12.8 开发工具链（nvcc + cudart/nvrtc/cublas 开发库，**不用** Ubuntu 源 `nvidia-cuda-toolkit`）和构建期编译好的 **llama.cpp**（`/deployment/software/llama.cpp`，CUDA 架构 61;75;86;89，含 P4 的 Pascal/sm_61）。仅支持 amd64；宿主机需安装 NVIDIA 驱动 + nvidia-container-toolkit，容器经 `--gpus all` 使用 GPU（镜像内不含驱动）。CUDA 必须 ≤ 12.x——CUDA 13 已移除 Pascal 支持。

| 镜像 | 包含组件 |
| --- | --- |
| [server/llamacpp/llamacpp-cuda](noble/server/llamacpp/llamacpp-cuda) | CUDA 12.8 工具链 + llama.cpp（/deployment/software/llama.cpp） |
| [server/llamacpp/llamacpp-cuda-py3.12-codeserver](noble/server/llamacpp/llamacpp-cuda-py3.12-codeserver) | llamacpp-cuda + Python 3.12 + code-server + SSH（开发镜像） |
| [server/llamacpp/llamacpp-vulkan](noble/server/llamacpp/llamacpp-vulkan) | Vulkan 后端 llama.cpp（AMD/核显，Mesa RADV，运行时映射 `/dev/dri`） |
| [server/llamacpp/llamacpp-rocm](noble/server/llamacpp/llamacpp-rocm) | ROCm 6.3/HIP 后端 llama.cpp（AMD 6900XT/gfx1030，运行时映射 `/dev/kfd`+`/dev/dri`） |

## 构建

```bash
REGISTRY=registry.cn-hangzhou.aliyuncs.com NAMESPACE=sarmn

# Desktop + Python 3.12
docker build \
  -f deployment/noble/desktop/python-extension-pack/py-3.12-codeserver-sshd-chrome-dbeaver-wps-vscode \
  -t $REGISTRY/$NAMESPACE/deployment:noble-desktop-python3.12-extension-pack \
  --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE .

# Server + Python 3.14
docker build \
  -f deployment/noble/server/python-extension-pack/py-3.14-codeserver-sshd \
  -t $REGISTRY/$NAMESPACE/deployment:noble-server-python3.14-extension-pack \
  --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE .

# llama.cpp CUDA（GPU 推理，仅 amd64）
docker build \
  -f deployment/noble/server/llamacpp/llamacpp-cuda \
  -t $REGISTRY/$NAMESPACE/deployment:noble-server-llamacpp-cuda \
  --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE .
# 可选 build-arg：LLAMACPP_VERSION=v0.4.0 / CUDA_SERIES=12-8 / CUDA_ARCHS="61;75;86;89"
```

## 使用

### 桌面环境

```bash
docker run -d --name dev-desktop \
  -p 6080:6080 -p 8080:8080 -p 2222:22 \
  -v $(pwd)/workspace:/deployment/workspace \
  -e VNC_PASSWORD="your-vnc-password" \
  $REGISTRY/$NAMESPACE/deployment:noble-desktop-python3.12-extension-pack
# → http://localhost:6080 noVNC 桌面
# → http://localhost:8080 code-server
# → ssh sarmn@localhost -p 2222
```

### 服务器环境

```bash
docker run -d --name dev-server \
  -p 8080:8080 -p 2222:22 \
  -v $(pwd)/workspace:/deployment/workspace \
  $REGISTRY/$NAMESPACE/deployment:noble-server-python3.14-extension-pack
# → http://localhost:8080 code-server
# → ssh sarmn@localhost -p 2222
```

### OpenResty + code-server

```bash
docker run -d --name nginx-code \
  -p 80:80 -p 8080:8080 \
  $REGISTRY/$NAMESPACE/deployment:noble-server-nginx-code
# → http://localhost:80   OpenResty
# → http://localhost:8080 code-server
```

### llama.cpp CUDA（GPU 推理）

`llama.cpp` 已在镜像内预编译（`/deployment/software/llama.cpp`，bin 已在 PATH），启动容器后手动拉起服务即可：

```bash
docker run -d --name llamacpp --gpus all \
  -p 8000:8000 \
  -v $(pwd)/models:/deployment/workspace/apps/models \
  $REGISTRY/$NAMESPACE/deployment:noble-server-llamacpp-cuda

docker exec -d llamacpp llama-server \
  --model /deployment/workspace/apps/models/qwen3-8b-q4_k_m.gguf --host 0.0.0.0 --port 8000 --n-gpu-layers 999
# → http://localhost:8000 llama-server（OpenAI 兼容 API: /v1/chat/completions）
```

模型不烤进镜像，挂载到 `/deployment/workspace/apps/models`。
镜像自带 CUDA 工具链，需要更新版本时也可在容器内重新编译（`git clone` 后按 Dockerfile 中的 cmake 参数构建，`GGML_CUDA=ON`、`-DCMAKE_CUDA_ARCHITECTURES="61;75;86;89"`）。

### llama.cpp AMD GPU（Vulkan / ROCm）

6900XT（RDNA2/gfx1030）等 AMD 卡用 `llamacpp-vulkan`（轻量稳定，推荐先试）或 `llamacpp-rocm`（性能更好）。llama.cpp 同样已预编译到 `/deployment/software/llama.cpp`：

```bash
# Vulkan：宿主机 Mesa RADV 驱动，映射 /dev/dri
docker run -d --name llamacpp-vk --device=/dev/dri \
  -p 8000:8000 \
  -v $(pwd)/models:/deployment/workspace/apps/models \
  $REGISTRY/$NAMESPACE/deployment:noble-server-llamacpp-vulkan

# ROCm：宿主机 amdgpu 内核驱动，映射 /dev/kfd + /dev/dri
docker run -d --name llamacpp-rocm --device=/dev/kfd --device=/dev/dri \
  -p 8000:8000 \
  -v $(pwd)/models:/deployment/workspace/apps/models \
  $REGISTRY/$NAMESPACE/deployment:noble-server-llamacpp-rocm

# 启动（两镜像相同）：
docker exec -d llamacpp-vk llama-server \
  --model /deployment/workspace/apps/models/model.gguf --host 0.0.0.0 --port 8000 --n-gpu-layers 999
```

### llama.cpp 开发镜像（+ Python 3.12 + code-server + SSH）

在 `llamacpp-cuda` 基础上叠加 Python 3.12、code-server（s6 自启动）和 sshd，用于 GPU 推理服务开发：

```bash
docker run -d --name llamacpp-dev --gpus all \
  -p 8000:8000 -p 8080:8080 -p 2222:22 \
  -v $(pwd)/workspace:/deployment/workspace \
  $REGISTRY/$NAMESPACE/deployment:noble-server-llamacpp-cuda-py3.12-codeserver
# → http://localhost:8080 code-server
# → ssh sarmn@localhost -p 2222
# 启动预装的 llama-server：
docker exec -d llamacpp-dev llama-server \
  --model /deployment/workspace/apps/models/model.gguf --host 0.0.0.0 --port 8000
# → http://localhost:8000 llama-server
```

业务代码约定放在 `/deployment/workspace/apps/api`（已加入 `PYTHONPATH`），模型放 `/deployment/workspace/apps/models`。

## 目录结构

```text
deployment/noble/
├── desktop/
│   └── python-extension-pack/
│       ├── py-3.12-codeserver-sshd-chrome-dbeaver-wps-vscode
│       └── py-3.14-codeserver-sshd-chrome-dbeaver-wps-vscode
└── server/
    ├── llamacpp/
    │   ├── llamacpp-cuda
    │   ├── llamacpp-cuda-py3.12-codeserver
    │   ├── llamacpp-vulkan
    │   └── llamacpp-rocm
    ├── nginx-code/
    │   └── openresty-nginx
    └── python-extension-pack/
        ├── py-3.12-codeserver-sshd
        └── py-3.14-codeserver-sshd
```

## 依赖关系

```text
ubuntu:noble ──► base:noble ──► base:noble-desktop
                    │                    │
                    ▼                    ▼
          language:noble-python-3.1x   software:noble-code-server
                    │           software:noble-chrome
                    │           software:noble-dbeaver
                    │           software:noble-wps
                    │           software:noble-vscode
                    │                    │
                    ▼                    ▼
               deployment ── (COPY --from 各层)
```
