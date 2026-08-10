# baseImage

基础镜像的安装与更新。推送地址由 CI 变量 `REGISTRY` / `NAMESPACE` 决定。

### 目录

- [基础镜像](#基础镜像)
- [语言镜像](#语言镜像)
- [middleware 镜像](#middleware-镜像)
- [software 镜像](#software-镜像)
- [deployment 镜像](#deployment-镜像)
- [CI 变量](#ci-变量)
- [默认密码](#默认密码)
- [使用说明](#使用说明)

### 使用说明

#### 镜像安装的基础软件列表

- 基础工具
  - vim、curl、wget、git、unzip、passwd
- 编译工具链
  - build-essential、pkg-config、llvm
  - libssl-dev、libffi-dev、libsqlite3-dev、zlib1g-dev 等
- 管理工具
  - s6-overlay (v3)
  - openssh-server（按需启动）
  - sudo
- Python 工具
  - uv（/usr/local/bin/uv）
- 中文字体（base-desktop）
  - fonts-wqy-zenhei、fonts-wqy-microhei
- 桌面环境（base-desktop）
  - Xfce4 + VNC + noVNC
  - fcitx5（中文输入法）

#### 软件安装目录结构

```text
/deployment
├── bin/                    # 可执行文件链接
├── software/               # 软件安装目录
│   ├── python/             # Python 各版本
│   ├── code-server/        # VS Code Server
│   ├── vscode/             # VS Code Desktop
│   ├── chrome/             # Chromium 浏览器
│   ├── dbeaver/            # DBeaver 数据库管理
│   ├── wps/                # WPS Office
│   ├── claude/             # Claude Code CLI
│   ├── clash-verge/        # Clash Verge 代理
│   ├── docker/             # Docker CLI
│   └── redis/              # Redis
├── openjdk/                # OpenJDK 各版本
├── scripts/                # 公共脚本（common.sh）
├── accounts/               # 用户/权限配置
│   └── sudoers.d/
├── workspace/              # 工作区
├── configs/                # 配置文件
├── logs/                   # 日志
└── data/                   # 数据目录
```

镜像名写法：`${REGISTRY}/${NAMESPACE}/<repo>:<tag>`  
例：`registry.cn-hangzhou.aliyuncs.com/sarmn/base:noble`

### 基础镜像

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/ubuntu:noble` | 官方 ubuntu:noble 同步镜像 |
| `${REGISTRY}/${NAMESPACE}/base:noble` | 基础镜像（s6、SSH、开发工具、用户） |
| `${REGISTRY}/${NAMESPACE}/base:noble-desktop` | 桌面基础镜像（Xfce + VNC + 中文字体） |

### 语言镜像

**Python**（均基于 `base:noble`）

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/language:noble-python-3.10` | Python 3.10 |
| `${REGISTRY}/${NAMESPACE}/language:noble-python-3.11` | Python 3.11 |
| `${REGISTRY}/${NAMESPACE}/language:noble-python-3.12` | Python 3.12 |
| `${REGISTRY}/${NAMESPACE}/language:noble-python-3.13` | Python 3.13 |
| `${REGISTRY}/${NAMESPACE}/language:noble-python-3.13-ft` | Python 3.13 free-threaded |
| `${REGISTRY}/${NAMESPACE}/language:noble-python-3.14` | Python 3.14 |
| `${REGISTRY}/${NAMESPACE}/language:noble-python-3.14-ft` | Python 3.14 free-threaded |
| `${REGISTRY}/${NAMESPACE}/language:noble-miniconda-3` | Miniconda 3 |

**Java / OpenJDK**（基于 `base:noble`，多阶段构建）

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/language:noble-openjdk-21` | OpenJDK 21 (amd64/arm64) |
| `${REGISTRY}/${NAMESPACE}/language:noble-openjdk-24` | OpenJDK 24 (amd64/arm64) |
| `${REGISTRY}/${NAMESPACE}/language:noble-openjdk-25` | OpenJDK 25 (amd64/arm64) |

### middleware 镜像

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/middleware:noble-redis-7.4` | Redis 7.4 |
| `${REGISTRY}/${NAMESPACE}/middleware:noble-redis-8.2` | Redis 8.2 |

### software 镜像

**后端服务**（基于 `base:noble`）

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/software:noble-code-server` | VS Code Server（密码通过 secret 注入） |
| `${REGISTRY}/${NAMESPACE}/software:noble-docker` | Docker CLI + docker-compose |
| `${REGISTRY}/${NAMESPACE}/software:noble-claude` | Claude Code CLI（基于 Node.js 22） |

**桌面应用**（基于 `base:noble-desktop`，均支持 amd64/arm64）

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/software:noble-chrome` | Chromium 浏览器（桌面快捷方式） |
| `${REGISTRY}/${NAMESPACE}/software:noble-dbeaver` | DBeaver 数据库管理工具（桌面快捷方式） |
| `${REGISTRY}/${NAMESPACE}/software:noble-wps` | WPS Office 办公套件（桌面快捷方式） |
| `${REGISTRY}/${NAMESPACE}/software:noble-vscode` | VS Code Desktop（含 Python 扩展） |
| `${REGISTRY}/${NAMESPACE}/software:noble-clash-verge` | Clash Verge 代理客户端（s6 自启动） |

### deployment 镜像

deployment 镜像在 software/language 分层基础上组合为**开箱即用**的场景镜像，CI 每日 UTC 22:00（北京时间 06:00）构建。

**桌面开发环境**（基于 `base:noble-desktop`，含 Xfce + Chrome + DBeaver + WPS + VS Code + code-server + SSH）

| 镜像 | Python | tag |
|---|---|---|
| `${REGISTRY}/${NAMESPACE}/deployment:noble-desktop-python3.12-extension-pack` | 3.12 | `noble-desktop-python3.12-extension-pack` |
| `${REGISTRY}/${NAMESPACE}/deployment:noble-desktop-python3.14-extension-pack` | 3.14 | `noble-desktop-python3.14-extension-pack` |

**服务器开发环境**（基于 `base:noble`，含 code-server + SSH）

| 镜像 | Python | tag |
|---|---|---|
| `${REGISTRY}/${NAMESPACE}/deployment:noble-server-python3.12-extension-pack` | 3.12 | `noble-server-python3.12-extension-pack` |
| `${REGISTRY}/${NAMESPACE}/deployment:noble-server-python3.14-extension-pack` | 3.14 | `noble-server-python3.14-extension-pack` |

> Dockerfile 位于 `deployment/noble/<desktop|server>/python-extension-pack/`，构建上下文为仓库根目录。

### CI 变量

GitHub Secrets 与 GitLab CI/CD Variables **同名**：

| 变量 | 必配 | 说明 |
|---|---|---|
| `REGISTRY` | 是 | 镜像仓库，如 `registry.cn-hangzhou.aliyuncs.com` |
| `NAMESPACE` | 是 | 命名空间 |
| `ALY_ARC_USERNAME` | 是 | 仓库登录用户名 |
| `ALY_ARC_PASSWORD` | 是 | 仓库登录密码 |
| `SARMN_PASSWORD` | 建议 | 默认业务用户 `sarmn` 密码 |
| `ROOT_PASSWORD` | 否 | root 密码，未设则构建时随机生成 |
| `VNC_PASSWORD` | 否 | desktop 镜像 VNC 密码 |
| `REDIS_PASSWORD` | 否 | Redis `requirepass` |
| `CODE_SERVER_PASSWORD` | 否 | code-server 登录密码 |

### 默认密码

CI / 本地构建未覆盖对应 secret 时，可按下列默认值配置（建议写入 Secrets，勿依赖镜像内明文）：

| 用途 | 变量 | 默认密码 |
|---|---|---|
| root | `ROOT_PASSWORD` | `Sam.Tech` |
| sarmn | `SARMN_PASSWORD` | `SArMnTop1` |
| VNC | `VNC_PASSWORD` | `Sam.5H8g` |
| Redis | `REDIS_PASSWORD` | `RdP.8G6h` |
| code-server | `CODE_SERVER_PASSWORD` | 随机生成 |

密码经 **BuildKit secret** 注入（`--secret`），不进入镜像 layer / `docker history`。

本地构建示例：

```bash
export REGISTRY=registry.cn-hangzhou.aliyuncs.com NAMESPACE=sarmn
export SARMN_PASSWORD='SArMnTop1'
export ROOT_PASSWORD='Sam.Tech'
docker buildx build \
  --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE \
  --secret id=SARMN_PASSWORD,env=SARMN_PASSWORD \
  --secret id=ROOT_PASSWORD,env=ROOT_PASSWORD \
  -f docker_installer/dockerfiles/base/Dockerfile \
  -t $REGISTRY/$NAMESPACE/base:noble .
```
