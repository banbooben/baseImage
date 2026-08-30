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

基于 `base:noble`，含 llama.cpp CUDA 版（不注册 s6 服务，`llama-server` 由用户自行启动）。仅支持 amd64；宿主机需安装 NVIDIA 驱动 + nvidia-container-toolkit，容器经 `--gpus all` 使用 GPU（镜像内只带 CUDA 运行时，不含驱动）。

| 镜像 | 包含组件 |
| --- | --- |
| [server/llamacpp/llamacpp-cuda](noble/server/llamacpp/llamacpp-cuda) | llama.cpp（CUDA 12.8 编译）+ CUDA 运行时 |

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
# 可选 build-arg：LLAMACPP_PIN_VERSION=b10690 / CUDA_SERIES=12-8 / CUDA_ARCHITECTURES="89;90"
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

```bash
docker run -d --name llamacpp --gpus all \
  -p 8000:8000 \
  -v $(pwd)/models:/deployment/workspace/apps/models \
  -e LLAMA_MODEL=/deployment/workspace/apps/models/qwen3-8b-q4_k_m.gguf \
  -e N_GPU_LAYERS=999 \
  $REGISTRY/$NAMESPACE/deployment:noble-server-llamacpp-cuda

# 镜像不含自启动服务，手动启动 llama-server：
docker exec -d llamacpp /deployment/software/llamacpp/start.sh
# 或直接指定参数：
docker exec -d llamacpp llama-server \
  --model /deployment/workspace/apps/models/qwen3-8b-q4_k_m.gguf --host 0.0.0.0 --port 8000 --n-gpu-layers 999
# → http://localhost:8000 llama-server（OpenAI 兼容 API: /v1/chat/completions）
```

模型不烤进镜像，挂载到 `/deployment/workspace/apps/models` 或用 `LLAMA_MODEL` 指定路径。`start.sh` 支持的环境变量：`LLAMA_MODEL` / `LLAMA_HOST` / `LLAMA_PORT` / `N_GPU_LAYERS` / `LLAMA_EXTRA_ARGS`。

## 目录结构

```text
deployment/noble/
├── desktop/
│   └── python-extension-pack/
│       ├── py-3.12-codeserver-sshd-chrome-dbeaver-wps-vscode
│       └── py-3.14-codeserver-sshd-chrome-dbeaver-wps-vscode
└── server/
    ├── llamacpp/
    │   └── llamacpp-cuda
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
