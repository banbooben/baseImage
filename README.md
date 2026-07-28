# baseImage

基础镜像的安装与更新。推送地址由 CI 变量 `REGISTRY` / `NAMESPACE` 决定。

### 目录
- [基础镜像](#基础镜像)
- [语言镜像](#语言镜像)
- [middleware 镜像](#middleware-镜像)
- [software 镜像](#software-镜像)
- [CI 变量](#ci-变量)
- [使用说明](#使用说明)

### 使用说明
#### 镜像安装的基础软件列表
- 软件
  - vim、curl、wget、git、cron
- 管理工具
  - s6-overlay

#### 软件安装目录结构
- `/deployment`
  - `/deployment/bin`
  - `/deployment/software/python`
  - `/deployment/openjdk`
  - `/deployment/hadoop`
  - `/deployment/hive`
  - `/deployment/software/redis`
  - `/deployment/scripts`

镜像名写法：`${REGISTRY}/${NAMESPACE}/<repo>:<tag>`  
例：`registry.cn-hangzhou.aliyuncs.com/sarmn/base:noble`

### 基础镜像
- `${REGISTRY}/${NAMESPACE}/ubuntu:noble`
- `${REGISTRY}/${NAMESPACE}/base:noble`
- `${REGISTRY}/${NAMESPACE}/base:noble-desktop`

### 语言镜像
- Python
  - `${REGISTRY}/${NAMESPACE}/language:noble-python-3.14`
  - `${REGISTRY}/${NAMESPACE}/language:noble-python-3.14-ft`
  - `${REGISTRY}/${NAMESPACE}/language:noble-python-3.13`
  - `${REGISTRY}/${NAMESPACE}/language:noble-python-3.13-ft`
  - `${REGISTRY}/${NAMESPACE}/language:noble-python-3.12`
  - `${REGISTRY}/${NAMESPACE}/language:noble-python-3.11`
  - `${REGISTRY}/${NAMESPACE}/language:noble-python-3.10`
  - `${REGISTRY}/${NAMESPACE}/language:noble-miniconda-3`
- Java
  - `${REGISTRY}/${NAMESPACE}/language:noble-openjdk-11`
  - `${REGISTRY}/${NAMESPACE}/language:noble-openjdk-24`
  - `${REGISTRY}/${NAMESPACE}/language:noble-openjdk-25`

### middleware 镜像
- Redis
  - `${REGISTRY}/${NAMESPACE}/middleware:noble-redis-7.4`
  - `${REGISTRY}/${NAMESPACE}/middleware:noble-redis-8.2`
- （可选，CI 中默认注释）
  - `${REGISTRY}/${NAMESPACE}/middleware:noble-mariadb-11.4`
  - `${REGISTRY}/${NAMESPACE}/middleware:noble-hadoop-3.4`
  - `${REGISTRY}/${NAMESPACE}/middleware:noble-hive-4`

### software 镜像
- `${REGISTRY}/${NAMESPACE}/software:noble-code-server`
- `${REGISTRY}/${NAMESPACE}/software:noble-docker`
- `${REGISTRY}/${NAMESPACE}/deployment:noble-desktop-chrome`

### CI 变量

GitHub Secrets 与 GitLab CI/CD Variables **同名**：

| 变量 | 必配 | 说明 |
|---|---|---|
| `REGISTRY` | 是 | 镜像仓库，如 `registry.cn-hangzhou.aliyuncs.com` |
| `NAMESPACE` | 是 | 命名空间 |
| `ALY_ARC_USERNAME` | 是 | 仓库登录用户名 |
| `ALY_ARC_PASSWORD` | 是 | 仓库登录密码 |
| `SARMN_PASSWORD` | 建议 | 默认业务用户 `sarmn` 密码 |
| `ROOT_PASSWORD` | 否 | 未设则构建时随机生成 |
| `VNC_PASSWORD` | 否 | desktop 镜像 VNC |
| `REDIS_PASSWORD` | 否 | Redis `requirepass` |
| `CODE_SERVER_PASSWORD` | 否 | code-server（GitLab） |
| `HIVE_DB_PASSWORD` | 否 | Hive metastore（启用 hive 时） |

密码经 **BuildKit secret** 注入（`--secret`），不进入镜像 layer / `docker history`。

本地构建示例：
```bash
export REGISTRY=registry.cn-hangzhou.aliyuncs.com NAMESPACE=sarmn
export SARMN_PASSWORD='your-password'
docker buildx build \
  --build-arg REGISTRY=$REGISTRY --build-arg NAMESPACE=$NAMESPACE \
  --secret id=SARMN_PASSWORD,env=SARMN_PASSWORD \
  -f docker_installer/dockerfiles/base/Dockerfile \
  -t $REGISTRY/$NAMESPACE/base:noble .
```
