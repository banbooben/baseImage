# baseImage

基础镜像的安装与更新。推送地址由 CI 变量 `REGISTRY` / `NAMESPACE` 决定。

### 目录

- [基础镜像](#基础镜像)
- [语言镜像](#语言镜像)
- [middleware 镜像](#middleware-镜像)
- [software 镜像](#software-镜像)
- [deployment 镜像](#deployment-镜像)
- [openEuler 支持](#openeuler-支持)
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
  - Ubuntu：fonts-wqy-zenhei、fonts-wqy-microhei
  - openEuler：wqy-zenhei-fonts、wqy-microhei-fonts
- 桌面环境（base-desktop）
  - Xfce4 + VNC + noVNC
  - 中文输入法：Ubuntu 用 fcitx5，openEuler 用 fcitx4 + XIM

> 上面是 Ubuntu 侧的包名；openEuler 侧同一份脚本经包名映射表换成 rpm 名，
> 详见 [openEuler 支持](#openeuler-支持) 的差异表。

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
│   ├── openjdk/            # OpenJDK 各版本（JAVA_HOME）
│   ├── noVNC/              # noVNC + websockify（base-desktop）
│   └── redis/              # Redis
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

下表 tag 中的 **`<os>`** 是发行版前缀，取值见 [openEuler 支持](#openeuler-支持)：

| `<os>` | 发行版 |
|---|---|
| `noble` | Ubuntu 24.04 LTS |
| `openeuler-24.03` | openEuler 24.03 LTS |

即 `base:<os>` 实际对应 `base:noble` 与 `base:openeuler-24.03` 两个镜像。

### 基础镜像

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/ubuntu:noble` | 官方 ubuntu:noble 同步镜像 |
| `${REGISTRY}/${NAMESPACE}/openeuler:24.03-lts` | 官方 openEuler 24.03 LTS 同步镜像（源自 quay.io） |
| `${REGISTRY}/${NAMESPACE}/base:<os>` | 基础镜像（s6、SSH、开发工具、用户） |
| `${REGISTRY}/${NAMESPACE}/base:<os>-desktop` | 桌面基础镜像（Xfce + VNC + 中文字体） |

### 语言镜像

**Python**（均基于 `base:<os>`）

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/language:<os>-python-3.10` | Python 3.10 |
| `${REGISTRY}/${NAMESPACE}/language:<os>-python-3.11` | Python 3.11 |
| `${REGISTRY}/${NAMESPACE}/language:<os>-python-3.12` | Python 3.12 |
| `${REGISTRY}/${NAMESPACE}/language:<os>-python-3.13` | Python 3.13 |
| `${REGISTRY}/${NAMESPACE}/language:<os>-python-3.13-ft` | Python 3.13 free-threaded |
| `${REGISTRY}/${NAMESPACE}/language:<os>-python-3.14` | Python 3.14 |
| `${REGISTRY}/${NAMESPACE}/language:<os>-python-3.14-ft` | Python 3.14 free-threaded |
| `${REGISTRY}/${NAMESPACE}/language:<os>-python-3.15` | Python 3.15 |
| `${REGISTRY}/${NAMESPACE}/language:<os>-python-3.15-ft` | Python 3.15 free-threaded |
| `${REGISTRY}/${NAMESPACE}/language:<os>-miniconda-3` | Miniconda 3 |

**Java / OpenJDK**（基于 `base:<os>`，多阶段构建）

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/language:<os>-openjdk-21` | OpenJDK 21 (amd64/arm64) |
| `${REGISTRY}/${NAMESPACE}/language:<os>-openjdk-24` | OpenJDK 24 (amd64/arm64) |
| `${REGISTRY}/${NAMESPACE}/language:<os>-openjdk-25` | OpenJDK 25 (amd64/arm64) |

### middleware 镜像

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/middleware:<os>-redis-7.4` | Redis 7.4 |
| `${REGISTRY}/${NAMESPACE}/middleware:<os>-redis-8.2` | Redis 8.2 |

### software 镜像

**后端服务**（基于 `base:<os>`）

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/software:<os>-code-server` | VS Code Server（密码通过 secret 注入） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-docker` | Docker CLI + docker-compose |
| `${REGISTRY}/${NAMESPACE}/software:<os>-claude` | Claude Code CLI（基于 Node.js 22） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-openresty` | OpenResty（Nginx + LuaJIT，源码编译，s6 自启动，端口 80） |

**桌面应用**（基于 `base:<os>-desktop`）

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/software:<os>-chrome` | Chromium 浏览器（桌面快捷方式） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-dbeaver` | DBeaver 数据库管理工具（桌面快捷方式） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-wps` | WPS Office 办公套件（桌面快捷方式） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-vscode` | VS Code Desktop（含 Python 扩展） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-clash-verge` | Clash Verge 代理客户端（s6 自启动） |

### deployment 镜像

deployment 镜像在 software/language 分层基础上组合为**开箱即用**的场景镜像。CI 每周日构建，
UTC 18:00 起 base，20:00 起 language / middleware / software，22:00 起 deployment
（即北京时间周一 02:00 / 04:00 / 06:00），按层序错开。

**桌面开发环境**（基于 `base:<os>-desktop`，含 Xfce + Chrome + DBeaver + WPS + VS Code + code-server + SSH）

| 镜像 | Python | tag |
|---|---|---|
| `${REGISTRY}/${NAMESPACE}/deployment:<os>-desktop-python3.12-extension-pack` | 3.12 | `noble-desktop-python3.12-extension-pack` |
| `${REGISTRY}/${NAMESPACE}/deployment:<os>-desktop-python3.14-extension-pack` | 3.14 | `noble-desktop-python3.14-extension-pack` |

**服务器开发环境**（基于 `base:<os>`，含 code-server + SSH）

| 镜像 | Python | tag |
|---|---|---|
| `${REGISTRY}/${NAMESPACE}/deployment:<os>-server-python3.12-extension-pack` | 3.12 | `noble-server-python3.12-extension-pack` |
| `${REGISTRY}/${NAMESPACE}/deployment:<os>-server-python3.14-extension-pack` | 3.14 | `noble-server-python3.14-extension-pack` |

> Dockerfile 位于 `deployment/common/<desktop|server>/python-extension-pack/`，构建上下文为仓库根目录。

### openEuler 支持

同一套代码树同时产出两个发行版的镜像。发行版差异收敛在安装脚本的抽象层
（`docker_installer/installer/common.sh` 的 `detect_distro` / `pkg_*` / `map_packages`），
20+ 个 installer 脚本本身不写 `if 发行版` 分支。

#### 支持的发行版

| `<os>` | 上游基础镜像 | 同步来源 | 架构 |
|---|---|---|---|
| `noble` | `ubuntu:24.04` | `docker.io/library/ubuntu:noble` | amd64, arm64 |
| `openeuler-24.03` | `openeuler/openeuler:24.03-lts` | `quay.io/openeuler/openeuler:24.03-lts` | amd64, arm64 |

> openEuler 走 quay.io 而不是 Docker Hub：Hub 在部分网络下不可达。`24.03-lts` 是原地更新的滚动 tag。

#### 本地构建

两个发行版用**同一个 Dockerfile**，只换 `OS_TAG` 与 `BASE_OS_IMAGE`：

```bash
export REGISTRY=registry.cn-hangzhou.aliyuncs.com NAMESPACE=sarmn
export SARMN_PASSWORD='SArMnTop1' ROOT_PASSWORD='Sam.Tech'

# Ubuntu 24.04（不传 OS_TAG 时即为此默认值，行为与旧版一致）
docker buildx build --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE \
  --secret id=SARMN_PASSWORD,env=SARMN_PASSWORD --secret id=ROOT_PASSWORD,env=ROOT_PASSWORD \
  -f docker_installer/dockerfiles/base/Dockerfile \
  -t $REGISTRY/$NAMESPACE/base:noble .

# openEuler 24.03 LTS
docker buildx build --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE \
  --build-arg OS_TAG=openeuler-24.03 \
  --build-arg BASE_OS_IMAGE=$REGISTRY/$NAMESPACE/openeuler:24.03-lts \
  --secret id=SARMN_PASSWORD,env=SARMN_PASSWORD --secret id=ROOT_PASSWORD,env=ROOT_PASSWORD \
  -f docker_installer/dockerfiles/base/Dockerfile \
  -t $REGISTRY/$NAMESPACE/base:openeuler-24.03 .
```

派生层不必再传 `BASE_OS_IMAGE`，`OS_TAG` 会逐层透传（各 Dockerfile 内 `ARG OS_TAG` 默认 `noble`）：

```bash
docker buildx build --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE \
  --build-arg OS_TAG=openeuler-24.03 \
  --build-arg PYTHON_PIN_VERSION=3.12.11 --secret id=CODE_SERVER_PASSWORD,env=CODE_SERVER_PASSWORD \
  -f docker_installer/dockerfiles/languages/python/python3.12 \
  -t $REGISTRY/$NAMESPACE/language:openeuler-24.03-python-3.12 .
```

#### 发行版差异

| 项目 | Ubuntu (noble) | openEuler 24.03 LTS |
|---|---|---|
| 包管理 | apt / dpkg | dnf / rpm |
| 编译工具链 | `build-essential` | `gcc gcc-c++ make` |
| 桌面环境 | Xfce4 4.18 | Xfce4 4.18（EPOL 源，同版本） |
| 中文 locale | `locales` + `locale-gen` | `glibc-all-langpacks`（无需生成） |
| 中文字体 | `fonts-wqy-zenhei`、`fonts-wqy-microhei` | `wqy-zenhei-fonts`、`wqy-microhei-fonts` |
| 中文输入法 | fcitx5（带 GTK/Qt immodule） | **fcitx 4.2.9 + XIM**（无 fcitx5 包；`GTK_IM_MODULE=xim`、`QT_IM_MODULE=xim`） |
| 剪贴板同步 | `autocutsel` | `xfce4-clipman`（无 autocutsel，随 `xfce4-goodies`） |
| 浏览器 | chromium（`ppa:xtradeb/apps`） | **Google Chrome 官方 .rpm** |
| sudo 组 | `sudo` | `wheel` |
| 架构辅助 | `dpkg-architecture` / `dpkg-buildflags` | `uname -m` 映射 / `rpm --eval '%{optflags}'` |

#### 已知缺口与待定项

| 项目 | 状态 |
|---|---|
| `chromium` | openEuler 全源无此包 → openEuler 变体改用 Google Chrome 官方 .rpm。官方同时发布 x86_64 与 aarch64 的 rpm，故 `software:<os>-chrome` 两个架构都能出；rpm 不带 chromedriver，改从 Chrome for Testing 按同架构（`linux64` / `linux-arm64`）补齐 |
| `fcitx5` | openEuler 只有 fcitx 4.2.9，桌面镜像改用 fcitx4 + XIM |
| Docker | 官方 apt 源 `docker-ce` | 无 `lsb-release`，改用发行版自带 `moby-engine`（24.03 里是 25.x；`docker-engine` 仍停在 18.09，不要选），buildx / compose 取上游静态二进制 |

> 未命中包名映射表的包名会**原样透传**给 dnf（两发行版同名的包占多数），便于渐进补齐。

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
