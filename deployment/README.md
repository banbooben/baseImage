# Deployment — 场景化开发镜像

在分层镜像基础上，组合多个软件为**开箱即用**的场景镜像。Dockerfile 位于 `deployment/common/` 下，构建上下文为仓库根目录。

> 目录名是 `common/` 而不是某个发行版代号：这些 Dockerfile 本身发行版中性，靠
> `--build-arg OS_TAG=<os>` 分出 Ubuntu / openEuler 两套镜像。下文 tag 里的
> **`<os>`** 取 `noble`（Ubuntu 24.04）或 `openeuler-24.03`，详见
> [主 README 的 openEuler 支持](../README.md#openeuler-支持)。

## 镜像列表

### 桌面开发环境

基于 `base:<os>-desktop`，含 Xfce 桌面 + VNC/noVNC + 中文输入法。

| 镜像 | 包含组件 |
| --- | --- |
| [desktop/python-extension-pack/py-3.12-codeserver-sshd-chrome-dbeaver-wps-vscode](common/desktop/python-extension-pack/py-3.12-codeserver-sshd-chrome-dbeaver-wps-vscode) | Python 3.12 + code-server + SSH + Chrome + DBeaver + WPS + VS Code |
| [desktop/python-extension-pack/py-3.14-codeserver-sshd-chrome-dbeaver-wps-vscode](common/desktop/python-extension-pack/py-3.14-codeserver-sshd-chrome-dbeaver-wps-vscode) | Python 3.14 + code-server + SSH + Chrome + DBeaver + WPS + VS Code |

### 服务器开发环境

基于 `base:<os>`，纯命令行环境。

| 镜像 | 包含组件 |
| --- | --- |
| [server/python-extension-pack/py-3.12-codeserver-sshd](common/server/python-extension-pack/py-3.12-codeserver-sshd) | Python 3.12 + code-server + SSH |
| [server/python-extension-pack/py-3.14-codeserver-sshd](common/server/python-extension-pack/py-3.14-codeserver-sshd) | Python 3.14 + code-server + SSH |
| [server/nginx-code/openresty-nginx](common/server/nginx-code/openresty-nginx) | OpenResty + code-server |

## 构建

下列命令里的 `<os>` 自行替换为 `noble` 或 `openeuler-24.03`；派生层不必传
`BASE_OS_IMAGE`，`OS_TAG` 会逐层透传。

```bash
export REGISTRY=registry.cn-hangzhou.aliyuncs.com NAMESPACE=sarmn

# Desktop + Python 3.12
docker build \
  -f deployment/common/desktop/python-extension-pack/py-3.12-codeserver-sshd-chrome-dbeaver-wps-vscode \
  -t $REGISTRY/$NAMESPACE/deployment:<os>-desktop-python3.12-extension-pack \
  --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE \
  --build-arg OS_TAG=<os> .

# Server + Python 3.14
docker build \
  -f deployment/common/server/python-extension-pack/py-3.14-codeserver-sshd \
  -t $REGISTRY/$NAMESPACE/deployment:<os>-server-python3.14-extension-pack \
  --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE \
  --build-arg OS_TAG=<os> .

```

## 使用

### 桌面环境

```bash
docker run -d --name dev-desktop \
  -p 6080:6080 -p 8080:8080 -p 2222:22 \
  -v $(pwd)/workspace:/deployment/workspace \
  -e VNC_PASSWORD="your-vnc-password" \
  $REGISTRY/$NAMESPACE/deployment:<os>-desktop-python3.12-extension-pack
# → http://localhost:6080 noVNC 桌面
# → http://localhost:8080 code-server
# → ssh sarmn@localhost -p 2222
```

### 服务器环境

```bash
docker run -d --name dev-server \
  -p 8080:8080 -p 2222:22 \
  -v $(pwd)/workspace:/deployment/workspace \
  $REGISTRY/$NAMESPACE/deployment:<os>-server-python3.14-extension-pack
# → http://localhost:8080 code-server
# → ssh sarmn@localhost -p 2222
```

### OpenResty + code-server

```bash
docker run -d --name nginx-code \
  -p 80:80 -p 8080:8080 \
  $REGISTRY/$NAMESPACE/deployment:<os>-server-nginx-code
# → http://localhost:80   OpenResty
# → http://localhost:8080 code-server
```

## 目录结构

```text
deployment/common/
├── desktop/
│   └── python-extension-pack/
│       ├── py-3.12-codeserver-sshd-chrome-dbeaver-wps-vscode
│       └── py-3.14-codeserver-sshd-chrome-dbeaver-wps-vscode
└── server/
    ├── nginx-code/
    │   └── openresty-nginx
    └── python-extension-pack/
        ├── py-3.12-codeserver-sshd
        └── py-3.14-codeserver-sshd
```

## 依赖关系

`<os>` ∈ {`noble`, `openeuler-24.03`}，两套发行版走完全相同的这张图：

```text
<os> 上游镜像 ──► base:<os> ──► base:<os>-desktop
                     │                    │
                     ▼                    ▼
          language:<os>-python-3.1x   software:<os>-code-server
                     │           software:<os>-chrome
                     │           software:<os>-dbeaver
                     │           software:<os>-wps
                     │           software:<os>-vscode
                     │                    │
                     ▼                    ▼
                deployment ── (COPY --from 各层)
```

