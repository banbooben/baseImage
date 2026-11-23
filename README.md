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
- [认证与密码](#认证与密码)
- [使用说明](#使用说明)

### 使用说明

#### 镜像安装的基础软件列表

- 基础工具
  - vim、curl、wget、git、unzip、passwd
- 编译工具链
  - build-essential、pkg-config
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
│   ├── apifox/             # Apifox API 工具（AppImage 解包）
│   ├── chrome/             # Chromium 浏览器
│   ├── dbeaver/            # DBeaver 数据库管理
│   ├── wps/                # WPS Office
│   ├── claude/             # Claude Code CLI
│   ├── llama.cpp/          # llama.cpp（CPU 推理 / OpenAI 兼容服务）
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
| `${REGISTRY}/${NAMESPACE}/base:<os>` | 基础镜像（s6、SSH、开发工具链、用户） |
| `${REGISTRY}/${NAMESPACE}/base:<os>-runtime` | 运行时基础镜像（只有运行期依赖，不含 gcc / -dev 头文件；语言与中间件镜像的最终层用它做 FROM） |
| `${REGISTRY}/${NAMESPACE}/base:<os>-desktop` | 桌面基础镜像（Xfce + VNC + 中文字体） |

### 语言镜像

> `base:<os>-runtime` 只含运行期依赖（无 gcc / make / -dev 头文件），语言镜像因此
> 比原先小约 0.5GB。需要在容器里从源码编译（`pip install` 无 wheel 的包等）时，
> 请自行 `pkg_install build-essential ...` 或基于 `base:<os>` 构建。

**Python**（编译阶段用 `base:<os>`，最终镜像用 `base:<os>-runtime`）

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

**Java / OpenJDK**（多阶段构建：构建阶段用 `base:<os>`，最终镜像用 `base:<os>-runtime`）

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

**后端服务**（`code-server` / `openresty` 最终层基于 `base:<os>-runtime`，其余基于 `base:<os>`）

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/software:<os>-code-server` | VS Code Server（运行期用 `-e PASSWORD=...` 提供密码） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-docker` | Docker CLI + docker-compose |
| `${REGISTRY}/${NAMESPACE}/software:<os>-claude` | Claude Code CLI（基于 Node.js 22） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-llama-cpp` | llama.cpp（CPU 推理，源码构建；x86_64 运行时按 CPU 特性分派，含 llama-cli / llama-server / llama-quantize 等） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-openresty` | OpenResty（Nginx + LuaJIT，源码编译，s6 自启动，端口 80） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-dingtalk-hermes` | 钉钉数字同事 backend（DWS + Hermes Agent + dingtalk-bridge 群桥守护进程） |

> 钉钉数字同事另有 desktop 变体：`deployment:<os>-desktop-python3.12/3.14-extension-pack-dingtalk-hermes`
> （基于桌面 extension-pack，Dockerfile 位于
> `deployment/common/desktop/python-extension-pack/Dockerfile-dingtalk-hermes`）。
> hermes 版另有宿主机文件系统约束：`~/.hermes` 卷必须在 POSIX 文件系统上
> （gateway 要 bind unix 控制套接字，exFAT 不支持会致命退出），详见镜像内
> `/deployment/software/dingtalk-hermes/README.md`。

> `software:<os>-llama-cpp` 只带 CPU 后端（CUDA/HIP/Vulkan 等由后续独立镜像按需扩展），
> 模型文件不打进镜像：运行时挂载 `/deployment/data/models` 或自行下载。例：
> `llama-server -m /deployment/data/models/model.gguf --host 0.0.0.0 --port 8081`。

**桌面应用**（基于 `base:<os>-desktop`）

| 镜像 | 说明 |
|---|---|
| `${REGISTRY}/${NAMESPACE}/software:<os>-chrome` | Chromium 浏览器（桌面快捷方式） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-dbeaver` | DBeaver 数据库管理工具（桌面快捷方式，预置常用 JDBC 驱动） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-wps` | WPS Office 办公套件（桌面快捷方式） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-vscode` | VS Code Desktop（含 Python 扩展） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-apifox` | Apifox API 工具（官方 AppImage 构建期解包，桌面快捷方式） |
| `${REGISTRY}/${NAMESPACE}/software:<os>-clash-verge` | Clash Verge 代理客户端（s6 自启动） |

> Apifox 使用官方 Linux AppImage，**构建期解包**到 `/deployment/software/apifox`，
> 运行期不需要 FUSE。解包用 `unsquashfs` 直接读 AppImage 里的 squashfs，不执行
> AppImage runtime —— 后者在 qemu-user 下会 `Exec format error`，这样 arm64 变体
> 也能在 amd64 runner 上构建。官方只提供 `-latest` 包，实际版本记录在 `APIFOX_VERSION`；
> 需要固定版本时用 `--build-arg APIFOX_DOWNLOAD_URL=<自建 zip>` 覆盖。

> DBeaver 构建期会**预置常用 JDBC 驱动**：读取当次安装的 DBeaver 自身 `plugin.xml` 驱动定义，
> 从阿里云 Maven 拉取对应 jar/pom（含传递依赖），按 DBeaver 的缓存布局写入
> `/deployment/software/dbeaver/data/DBeaverData/drivers/maven/aliyun`。覆盖
> MySQL / MariaDB / PostgreSQL / Oracle / SQL Server / SQLite / H2 / ClickHouse /
> StarRocks / Doris / TiDB / IoTDB / DuckDB / Hive / DB2 / Snowflake / Greenplum /
> Firebird，以及达梦 / 人大金仓 / GBase 8s / OceanBase / 崖山 / 华为 GaussDB。
> 版本随 DBeaver 升级自动更新；CI 每次构建都会传 `DBEAVER_CACHE_BUST`
> 强制重建驱动层，所以每次产出的都是构建当时最新的 DBeaver 与驱动（本地重建时传
> `--build-arg DBEAVER_CACHE_BUST=$(date +%s)` 同理）。
> GaussDB（openGauss）的驱动是华为云 https 直链（gsjdbc4），按 DBeaver 远程库规则缓存到
> `drivers/remote/...`。DBeaver CE 本身不带 Redis 驱动，镜像用社区驱动
> dbVisitor 在 **Generic JDBC** 下预置了 **Redis**（`jdbc:dbvisitor:jedis://{host}:{port}?database={database}`，
> 自包含 `-alone` 包，配置见 `<workspace>/.metadata/.config/drivers.xml`）。
> RabbitMQ 是 AMQP 消息队列、没有 JDBC 驱动，DBeaver 不支持，请用 Management UI / `rabbitmqadmin`。
> 用 `--build-arg DBEAVER_DRIVER_IDS=mysql8,postgres-jdbc,...` 可裁剪清单。
> DBeaver 内 Maven 默认仓库已配置为阿里云，缺的驱动仍可在「驱动管理器 → 库 → 下载/更新」
> 联网补装。内网部署时把 `DBeaverData/drivers` 目录整体拷到同一路径即可（保持 DBeaver
> 版本与目录属主一致）。
>
> 构建期还会生成完整的 `custom-drivers.xml`（安装到 `<workspace>/.metadata/.config/drivers.xml`），
> 为每个已预取库记录 `<file>` 条目。DBeaver 判断"驱动是否齐全"看的是这份记录而不是缓存
> 目录本身——没有它，jar 虽然已在缓存里，首次连接仍会弹"下载驱动文件"对话框。H2 /
> DuckDB / SQL Server 等定义里的 license 直链（`raw.githubusercontent.com`）也一并预取；
> 构建网络拿不到时该库写成 `disabled="true"`，不影响连接。有了完整记录，即使
> `RELEASE` / `[LATEST]` 形式的驱动（SQLite、DuckDB、TiDB、IoTDB、崖山）运行期也不再
> 查 Maven 元数据；只会在缓存被删或手动更新驱动时重新联网。详见镜像内
> `/deployment/software/dbeaver/README.md`。

### deployment 镜像

deployment 镜像在 software/language 分层基础上组合为**开箱即用**的场景镜像。

CI 由 `.github/workflows/build-all.yml` 每周日 UTC 18:00（北京时间周一 02:00）触发**整条依赖链**。
层序由 `needs:` 表达：上游 workflow 内**全部 job 成功**才触发下一层，任一层失败则下游不产出。

```text
base ─┬─ python ────┐
      ├─ java       │
      ├─ middleware │
      └─ software ──┘
           └─────────┴─→ deployment（needs: base, python, software）
```

deployment 的 7 个 Dockerfile 只 `FROM` base / language(python) / software 三者的产物，
不消费 java 与 middleware，所以它不 gate 在那两者上 —— 它们照常并行构建。

**不再按时间错峰。** 旧方案是 3.5 小时间隔（base 18:00 → 语言/中间件/软件 21:30 →
deployment 次日 01:00），错峰要求"上一层整套构建+推送的耗时 < 固定间隔"，而耗时随版本、
QEMU、网络波动：一旦某次变慢，后一层拉到的仍是上周推上去的同名 tag，会**静默**产出
跨周混合的镜像（这周的 base + 上周的 python）且不报错。改用 `needs:` 后顺序是确定性的，
层与层之间也没有空等。

单层重建：手动触发（`workflow_dispatch`）对应的 `build-<层>-images.yml`；整链重跑：手动触发 `build-all.yml`。
单个镜像重建：llama.cpp 用 `build-llama-cpp-images.yml`（可指定版本，留空取最新 release），
钉钉数字同事用 `build-dingtalk-hermes-images.yml`，Apifox 用 `build-apifox-images.yml`
（可覆盖下载地址；不进入每周链，需要时手动触发）。

**桌面开发环境**（基于 `base:<os>-desktop`，含 Xfce + Chrome + DBeaver + WPS + VS Code + Apifox + code-server + SSH）

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
（`images/common.sh` 的 `detect_distro` / `pkg_*` / `map_packages`），
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

# Ubuntu 24.04（不传 OS_TAG 时即为此默认值，行为与旧版一致）
docker buildx build --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE \
  -f images/base/Dockerfile \
  -t $REGISTRY/$NAMESPACE/base:noble .

# openEuler 24.03 LTS
docker buildx build --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE \
  --build-arg OS_TAG=openeuler-24.03 \
  --build-arg BASE_OS_IMAGE=$REGISTRY/$NAMESPACE/openeuler:24.03-lts \
  -f images/base/Dockerfile \
  -t $REGISTRY/$NAMESPACE/base:openeuler-24.03 .
```

派生层不必再传 `BASE_OS_IMAGE`，`OS_TAG` 会逐层透传（各 Dockerfile 内 `ARG OS_TAG` 默认 `noble`）。
语言镜像为单一参数化 Dockerfile：`images/languages/python/Dockerfile` 用 `PYTHON_SERIES`
（free-threaded 版本再加 `PYTHON_DISABLE_GIL=true`），`images/languages/java/Dockerfile` 用 `JDK_VERSION`：

```bash
docker buildx build --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE \
  --build-arg OS_TAG=openeuler-24.03 \
  --build-arg PYTHON_SERIES=3.12 --build-arg PYTHON_PIN_VERSION=3.12.11 \
  -f images/languages/python/Dockerfile \
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

### 认证与密码

镜像**不写入任何密码文件**，构建期也不接收密码类 secret。需要密码时在**容器启动时**
通过环境变量注入 —— 按实例生效，改密码只需重启容器，且不会进入镜像层。
唯一的例外是 VNC 的**默认密码**（见下表），用于保证桌面镜像开箱可用：

| 变量 | 作用 | 不设置时 |
|---|---|---|
| `SAM_PASSWORD` | 设置业务用户 `sam` 的密码；同时开启 SSH 密码登录，并把 `sam` 的 sudo 切回**需要密码** | 账户锁定，仅密钥登录，免密 sudo |
| `VNC_PASSWORD` | 桌面镜像启动时生成 `~/.vnc/passwd`（TigerVNC 只取前 8 个字符） | 使用默认密码 `Sam.5H8g` |
| `REDIS_PASSWORD` | Redis 启动时生成追加 `requirepass` 的运行期配置（覆盖 conf 里的同名指令） | 无 `requirepass` |

```bash
docker run -d \
  -e SAM_PASSWORD='你的密码' \
  -e VNC_PASSWORD='你的密码' \
  -e REDIS_PASSWORD='你的密码' \
  ...
```

注意：

- 环境变量对能执行 `docker inspect` 的人可见。更严格的环境优先用挂载文件：
  VNC 挂 `~/.vnc/passwd`（优先于 `VNC_PASSWORD`），Redis 挂自己的 `redis.conf`。
- `SAM_PASSWORD` 是声明式的：每次启动都会重新设置；去掉变量重启会把 `sam` 重新锁定。
  去掉变量时 SSH 密码登录也会被关回 `no`。
- **SSH**：默认 root 与 `sam` 均无密码，`PasswordAuthentication no`，仅允许密钥登录；
  `sam` 的密钥对在构建时生成于 `~/.ssh/id_rsa`（公钥已写入 `authorized_keys`）。
- **sudo**：默认免密（`/deployment/accounts/sudoers.d/sam`）；设置了 `SAM_PASSWORD`
  时改为常规的密码校验。`root` 始终免密。
- **VNC**：未设置 `VNC_PASSWORD` 时使用默认密码 **`Sam.5H8g`**（写在镜像的
  `15-vnc-password` 里），桌面开箱即用。默认密码是公开值，**对任何能访问 VNC/noVNC
  端口的人有效，生产环境务必覆盖**：`-e VNC_PASSWORD='你的密码'`。
  也可以挂载密码文件（优先级高于环境变量；文件必须 `0600`）：
  ```bash
  printf '你的密码' | vncpasswd -f > /deployment/accounts/sam/.vnc/passwd
  chmod 600 /deployment/accounts/sam/.vnc/passwd
  ```
- **code-server**：运行期通过环境变量 `PASSWORD`（或 `HASHED_PASSWORD`）提供；
  未提供时 code-server 拒绝启动，不会生成默认密码。
- **Redis**：默认无 `requirepass`；`REDIS_PASSWORD` 生成的运行期配置在
  `/run/redis/redis.conf`（权限 600、属主 `sam`），不会改写镜像内的 `redis.conf`。

本地构建示例：

```bash
export REGISTRY=registry.cn-hangzhou.aliyuncs.com NAMESPACE=sarmn
docker buildx build \
  --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE \
  -f images/base/Dockerfile \
  -t $REGISTRY/$NAMESPACE/base:noble .
```

### 运行用户与 PUID/PGID

镜像内以 `sam` 常驻的服务（vnc / desktop / clash-verge / redis / dingtalk-hermes 等）
默认使用 base 层 `create_user` 分配的 uid/gid（通常 1001，上游 `ubuntu` 用户占用 1000）。挂载卷在宿主机上的属主
若是别的 uid/gid，可在启动时用环境变量 `PUID` / `PGID` 把 `sam` 的 uid/gid 对齐过去，
避免读写权限错配：

```bash
docker run -d \
  -e PUID=$(id -u) -e PGID=$(id -g) \
  -v some_data:/deployment/software/<app> \
  ...
```

- 对齐在 base 层 `/etc/cont-init.d/05-puid-pgid` 完成，早于**所有** s6 服务启动；
  镜像内所有以 `sam` 常驻的服务一并生效，各服务零改动。
- 不设 `PUID` / `PGID` 时保持 bake 默认（1000），行为与未提供该特性时完全一致。
- 只影响 uid/gid，不改变家目录（始终 `/deployment/accounts/sam`）。
- 非法值（非数字）只告警跳过，不会把容器 init 打挂。
- `sshd` / `code-server` / `openresty` 等本来就是 root 的服务不受影响。
