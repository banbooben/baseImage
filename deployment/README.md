# Deployment — 场景化开发镜像

在现有分层镜像基础上，组合多个软件为**开箱即用**的场景镜像。

每个子目录对应一个 Dockerfile，构建上下文为仓库根目录。

## 镜像列表

| 镜像 | 基础 | 包含组件 |
| --- | --- | --- |
| [python-ide](python-ide/) | `base:noble` | Python 3.14 + code-server + uv |
| [java-ide](java-ide/) | `base:noble` | OpenJDK 25 + code-server |
| [polyglot](polyglot/) | `base:noble` | Python 3.14 + OpenJDK 25 + code-server |
| [workstation](workstation/) | `base:noble-desktop` | Xfce + Chrome + DBeaver + WPS + Clash Verge + code-server |

## 构建

```bash
# 所有构建均从仓库根目录发起
REGISTRY=registry.cn-hangzhou.aliyuncs.com NAMESPACE=sarmn

# Python IDE（需先构建 base:noble 及依赖层）
docker build \
  -f deployment/python-ide/Dockerfile \
  -t $REGISTRY/$NAMESPACE/python-ide:noble .

# Java IDE
docker build \
  -f deployment/java-ide/Dockerfile \
  -t $REGISTRY/$NAMESPACE/java-ide:noble .

# 多语言 IDE
docker build \
  -f deployment/polyglot/Dockerfile \
  -t $REGISTRY/$NAMESPACE/polyglot:noble .

# 远程工作站（code-server 密码通过 secret 注入）
export CODE_SERVER_PASSWORD="your-password"
docker build \
  -f deployment/workstation/Dockerfile \
  --secret id=CODE_SERVER_PASSWORD,env=CODE_SERVER_PASSWORD \
  -t $REGISTRY/$NAMESPACE/workstation:noble .
```

## 使用

### Python IDE

```bash
docker run -d --name py-ide \
  -p 8080:8080 -p 2222:22 \
  -v $(pwd)/workspace:/deployment/workspace \
  $REGISTRY/$NAMESPACE/python-ide:noble
# → http://localhost:8080 打开 code-server
# → ssh sarmn@localhost -p 2222
```

### Java IDE

```bash
docker run -d --name java-ide \
  -p 8080:8080 -p 2222:22 \
  -v $(pwd)/workspace:/deployment/workspace \
  $REGISTRY/$NAMESPACE/java-ide:noble
```

### Polyglot（Python + Java）

```bash
docker run -d --name polyglot \
  -p 8080:8080 -p 2222:22 \
  -v $(pwd)/workspace:/deployment/workspace \
  $REGISTRY/$NAMESPACE/polyglot:noble
```

### Workstation（远程桌面）

```bash
docker run -d --name workstation \
  -p 6080:6080 -p 8080:8080 -p 2222:22 \
  -v $(pwd)/workspace:/deployment/workspace \
  -v $(pwd)/clash-config:/deployment/software/clash-verge/data/config \
  -e VNC_PASSWORD="your-vnc-password" \
  $REGISTRY/$NAMESPACE/workstation:noble
# → http://localhost:6080 打开桌面（Xfce）
# → http://localhost:8080 code-server
```

## 切换版本

修改 Dockerfile 中的 `COPY` 路径即可：

```dockerfile
# Python 3.14 → 3.13
COPY ./docker_installer/installer/languages/python/install_python_3.13.sh  /tmp/install_python.sh

# OpenJDK 25 → 21
COPY ./docker_installer/installer/languages/java/install_openjdk_21.sh  /tmp/install_java.sh
```

## 自定义

每个 Dockerfile 可自由添加/移除组件，只需在 `RUN` 中增减对应的 `/tmp/install_xxx.sh` 调用行，并在 `ENV` 中补充相应的环境变量。
