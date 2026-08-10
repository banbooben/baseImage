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

## 目录结构

```text
deployment/noble/
├── desktop/
│   └── python-extension-pack/
│       ├── py-3.12-codeserver-sshd-chrome-dbeaver-wps-vscode
│       └── py-3.14-codeserver-sshd-chrome-dbeaver-wps-vscode
└── server/
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
