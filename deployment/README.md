# Deployment — 场景化开发镜像

在分层镜像基础上，组合多个软件为**开箱即用**的场景镜像。Dockerfile 位于 `deployment/common/` 下，构建上下文为仓库根目录。

> 目录名是 `common/` 而不是某个发行版代号：这些 Dockerfile 本身发行版中性，靠
> `--build-arg OS_TAG=<os>` 分出 Ubuntu / openEuler 两套镜像。下文 tag 里的
> **`<os>`** 取 `noble`（Ubuntu 24.04）或 `openeuler-24.03`，详见
> [主 README 的 openEuler 支持](../README.md#openeuler-支持)。

## 镜像列表

### 桌面开发环境

基于 `base:<os>-desktop`，含 Xfce 桌面 + VNC/noVNC + 中文输入法。

| 镜像 | Dockerfile | 包含组件 |
| --- | --- | --- |
| `deployment:<os>-desktop-python3.14-extension-pack` | [desktop/python-extension-pack/Dockerfile](common/desktop/python-extension-pack/Dockerfile)（`PYTHON_SERIES=3.14`） | Python 3.14 + code-server + SSH + Chrome + DBeaver + WPS + VS Code + Apifox |

### 服务器开发环境

基于 `base:<os>`，纯命令行环境。

| 镜像 | Dockerfile | 包含组件 |
| --- | --- | --- |
| `deployment:<os>-server-python3.14-extension-pack` | [server/python-extension-pack/Dockerfile](common/server/python-extension-pack/Dockerfile)（`PYTHON_SERIES=3.14`） | Python 3.14 + code-server + SSH |
| `deployment:<os>-server-nginx-code` | [server/nginx-code/openresty-nginx](common/server/nginx-code/openresty-nginx) | OpenResty + code-server |

## 构建

下列命令里的 `<os>` 自行替换为 `noble` 或 `openeuler-24.03`；派生层不必传
`BASE_OS_IMAGE`，`OS_TAG` 会逐层透传。

```bash
export REGISTRY=registry.cn-hangzhou.aliyuncs.com NAMESPACE=sarmn

# Desktop + Python 3.14
docker build \
  -f deployment/common/desktop/python-extension-pack/Dockerfile \
  -t $REGISTRY/$NAMESPACE/deployment:<os>-desktop-python3.14-extension-pack \
  --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE \
  --build-arg OS_TAG=<os> --build-arg PYTHON_SERIES=3.14 .

# Server + Python 3.14
docker build \
  -f deployment/common/server/python-extension-pack/Dockerfile \
  -t $REGISTRY/$NAMESPACE/deployment:<os>-server-python3.14-extension-pack \
  --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE \
  --build-arg OS_TAG=<os> --build-arg PYTHON_SERIES=3.14 .

```

## 使用

### 桌面环境

```bash
docker run -d --name dev-desktop \
  -p 6080:6080 -p 8080:8080 -p 2222:22 \
  -v $(pwd)/workspace:/deployment/workspace \
  -v $(pwd)/sam-home:/deployment/accounts/sam \
  $REGISTRY/$NAMESPACE/deployment:<os>-desktop-python3.14-extension-pack
# → http://localhost:6080 noVNC 桌面
# → http://localhost:8080 code-server（需 -e PASSWORD=...）
# → ssh sam@localhost -p 2222（仅密钥登录）
#
# 默认 VNC 密码为 Sam.5H8g，可直接访问；生产环境用 -e VNC_PASSWORD=... 覆盖。
# 也可以挂载密码文件（优先级更高，文件需 0600）：
#   mkdir -p sam-home/.vnc
#   printf '你的密码' | vncpasswd -f > sam-home/.vnc/passwd
#   chmod 600 sam-home/.vnc/passwd
# 需要 sam 密码登录时加 -e SAM_PASSWORD=...（同时开启 SSH 密码登录、sudo 需密码）。
```

### 服务器环境

```bash
docker run -d --name dev-server \
  -p 8080:8080 -p 2222:22 \
  -v $(pwd)/workspace:/deployment/workspace \
  $REGISTRY/$NAMESPACE/deployment:<os>-server-python3.14-extension-pack
# → http://localhost:8080 code-server（需 -e PASSWORD=...）
# → ssh sam@localhost -p 2222（仅密钥登录）
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
│       └── Dockerfile                # PYTHON_SERIES 必填（3.14）
└── server/
    ├── nginx-code/
    │   └── openresty-nginx
    └── python-extension-pack/
        └── Dockerfile                # PYTHON_SERIES 必填（3.14）
```

## 依赖关系

`<os>` 目前只有 `noble`（openEuler 24.03 已停用，2026-11），走这张图：

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

> **钉钉数字同事**：桌面版的 `-dingtalk-hermes` 变体已移除，只保留 server 版
> `software:resolute-dingtalk-hermes`（`FROM base:resolute`，Ubuntu 26.04），由独立的
> `build-dingtalk-hermes-images.yml` 单独构建。运行期由 s6 常驻两个服务：hermes gateway
> 与 dingtalk-bridge 群桥。

