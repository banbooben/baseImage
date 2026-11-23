#!/bin/bash
###
 # Install DBeaver CE under /deployment/software/dbeaver and prefetch common JDBC drivers.
 #
 # 驱动不再手工钉版本，而是构建期读当前 DBeaver 的 plugin.xml 驱动定义，
 # 把定义里 maven: 坐标对应的 jar/pom（含传递依赖）预取到 DBeaver 自己的缓存布局：
 #   ${DBEAVER_DATA}/DBeaverData/drivers/maven/aliyun/<groupId>/<artifact>-<version>.jar
 # 同时生成 custom-drivers.xml（安装到 <workspace>/.metadata/.config/drivers.xml），
 # 记录每个预取库的 <file> 条目——DBeaver 靠这份记录判断"驱动已就绪"，
 # 光有缓存文件仍会弹下载框。运行期 DBeaver 据此不再联网；
 # 缺的驱动仍可在 GUI（驱动管理器 → 库 → 下载/更新）下载，
 # Maven 默认仓库已切到阿里云（maven-repositories.xml）。
 #
 # Layer layout (COPY-friendly):
 #   /deployment/software/dbeaver/           # app + bundled JRE + dbeaver.sh + prefetch-drivers.py
 #   /deployment/software/dbeaver/data/      # DBEAVER_DATA：DBeaverData/ 驱动缓存 + workspace/
 #   /deployment/bin/dbeaver                 # launcher
###
source /deployment/scripts/common.sh

check_target_arch(){
  ARCH=$(uname -m)
  case $ARCH in
      x86_64|amd64)
          TARGET_ARCH="x86_64"
          ;;
      aarch64|arm64)
          TARGET_ARCH="aarch64"
          ;;
      *)
          echo "未知架构: $ARCH"
          exit 1
          ;;
  esac
  export TARGET_ARCH
  echo "目标架构: $TARGET_ARCH"
}

setEnv(){
  check_target_arch
  export DEBIAN_FRONTEND=noninteractive
  export INSTALL_PATH=/deployment/software/dbeaver
  export DBEAVER_DATA="${INSTALL_PATH}/data"

  # 预取驱动时 Maven 仓库（同时写进 DBeaver 运行期配置）
  export MAVEN_CENTRAL_PRIMARY="${MAVEN_CENTRAL_PRIMARY:-https://maven.aliyun.com/repository/central}"
  export MAVEN_CENTRAL_FALLBACK="${MAVEN_CENTRAL_FALLBACK:-https://repo1.maven.org/maven2}"
  # 逗号分隔的 driver id；留空用脚本里的默认清单
  export DBEAVER_DRIVER_IDS="${DBEAVER_DRIVER_IDS:-}"

  # App version (override with DBEAVER_PIN_VERSION=26.1.3)
  DBEAVER_VERSION="$(resolve_github_latest_tag dbeaver/dbeaver DBEAVER_PIN_VERSION)" || return 1
  export DBEAVER_VERSION

  echo "Using DBeaver CE ${DBEAVER_VERSION} (${TARGET_ARCH})"
}

installDeps(){
  # base-desktop 已有 gtk/X/gl/中文字体；仅补实测缺失项
  # python3 用于构建期解析驱动定义并下载驱动
  export DEBIAN_FRONTEND=noninteractive
  pkg_update
  pkg_install libwebkit2gtk-4.1-0 at-spi2-core python3 \
    || pkg_install at-spi2-core python3 || true
  pkg_clean
}

installDBeaver(){
  # DBeaver 官方 tar.gz 自带 JRE，deb/rpm 之外还有这个发行版中立的包，
  # 两个发行版共用，无需按 DISTRO_FAMILY 分叉
  local archive="dbeaver-ce-${DBEAVER_VERSION}-linux-${TARGET_ARCH}.tar.gz"
  local url_gh="https://github.com/dbeaver/dbeaver/releases/download/${DBEAVER_VERSION}/${archive}"
  local url_io="https://dbeaver.io/files/${DBEAVER_VERSION}/${archive}"
  local tmp="/tmp/${archive}"

  mkdir -p /deployment/software /deployment/bin
  rm -rf "${INSTALL_PATH}"

  echo "download DBeaver ${archive}"
  if ! wget -q --timeout=120 -O "${tmp}" "${url_gh}"; then
    echo "GitHub download failed, try dbeaver.io"
    wget -q --timeout=120 -O "${tmp}" "${url_io}" || {
      echo "Failed to download DBeaver archive" >&2
      return 1
    }
  fi

  # 官方 tar.gz 解包后就是 ./dbeaver
  tar -xzf "${tmp}" -C /deployment/software
  rm -f "${tmp}"

  if [ ! -x "${INSTALL_PATH}/dbeaver" ]; then
    echo "dbeaver binary missing in ${INSTALL_PATH}" >&2
    return 1
  fi

  mkdir -p "${DBEAVER_DATA}" /deployment/bin

  # 预取脚本随镜像保留，DBeaver 升级后可手动重跑
  if [ -f /tmp/dbeaver_prefetch.py ]; then
    install -m 0755 /tmp/dbeaver_prefetch.py "${INSTALL_PATH}/prefetch-drivers.py"
  fi

  write_cont_env DBEAVER_VERSION "${DBEAVER_VERSION}"
  write_cont_env DBEAVER_HOME "${INSTALL_PATH}"
  write_cont_env DBEAVER_DATA "${DBEAVER_DATA}"

  # Persist for merge_and_save_env / child images
  {
    echo "export DBEAVER_HOME=${INSTALL_PATH}"
    echo "export DBEAVER_DATA=${DBEAVER_DATA}"
    echo "export DBEAVER_VERSION=${DBEAVER_VERSION}"
    echo "export PATH=${INSTALL_PATH}:/deployment/bin:\$PATH"
  } >> /etc/environment
}

downloadDrivers(){
  # DBeaver 运行期按 repo id 分目录缓存，所以这里的 repoId 必须和
  # maven-repositories.xml 里定义的 id 一致（aliyun）
  local drivers_root="${DBEAVER_DATA}/DBeaverData/drivers"
  local cache_root="${drivers_root}/maven/aliyun"

  if [ ! -f "${INSTALL_PATH}/prefetch-drivers.py" ]; then
    echo "ERROR: prefetch-drivers.py missing" >&2
    return 1
  fi

  echo "Prefetch JDBC drivers from ${MAVEN_CENTRAL_PRIMARY} ..."
  DBEAVER_PLUGINS="${INSTALL_PATH}/plugins" \
  DBEAVER_DRIVER_CACHE="${cache_root}" \
  DBEAVER_DRIVERS_HOME="${drivers_root}" \
  DBEAVER_CUSTOM_DRIVERS_OUT="${INSTALL_PATH}/custom-drivers.xml" \
  MAVEN_CENTRAL_PRIMARY="${MAVEN_CENTRAL_PRIMARY}" \
  MAVEN_CENTRAL_FALLBACK="${MAVEN_CENTRAL_FALLBACK}" \
  python3 "${INSTALL_PATH}/prefetch-drivers.py" || {
    echo "ERROR: JDBC driver prefetch failed" >&2
    return 1
  }

  # 清单方便排查/COPY
  {
    echo "# DBeaver prefetched JDBC drivers"
    echo "DBEAVER_VERSION=${DBEAVER_VERSION}"
    echo "MAVEN_CACHE=${cache_root}"
    find "${cache_root}" -type f -name '*.jar' 2>/dev/null | sort | sed "s#^${cache_root}/#MAVEN_JAR=#"
    if [ -d "${drivers_root}/remote" ]; then
      find "${drivers_root}/remote" -type f -name '*.jar' 2>/dev/null | sort \
        | sed "s#^${drivers_root}/remote/#REMOTE_JAR=#"
    fi
  } > "${DBEAVER_DATA}/DRIVERS-MANIFEST.txt"

  echo "Drivers ready under ${drivers_root}"
}

initConfig(){
  # DBeaver 运行期 Maven 仓库配置：默认走阿里云，保留 maven-central 作为兜底。
  # 路径见 BasePlatformImpl.getLocalWorkspaceConfigFolder(): <workspace>/.metadata/.config
  cat > "${INSTALL_PATH}/maven-repositories.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<maven>
  <repository id="aliyun" name="Aliyun Maven Central"
              url="https://maven.aliyun.com/repository/central"
              order="-1" enabled="true"/>
</maven>
EOF

  # Launcher wrapper: isolate data dir so the whole tree is relocatable / COPY-able
  cat > "${INSTALL_PATH}/dbeaver.sh" <<EOF
#!/bin/bash
export DBEAVER_HOME="${INSTALL_PATH}"
export DBEAVER_DATA="\${DBEAVER_DATA:-${DBEAVER_DATA}}"
# Keep Eclipse/DBeaver user data inside the software tree (not \$HOME), so child images can COPY one layer.
mkdir -p "\${DBEAVER_DATA}"
# 首次启动（或挂载了全新的 data 卷）时补上阿里云 Maven 仓库配置
cfg_dir="\${DBEAVER_DATA}/workspace/.metadata/.config"
mkdir -p "\${cfg_dir}" 2>/dev/null
if [ ! -f "\${cfg_dir}/maven-repositories.xml" ]; then
  cp -f "${INSTALL_PATH}/maven-repositories.xml" "\${cfg_dir}/" 2>/dev/null || true
fi
# 预置自定义驱动（Redis / dbVisitor）；已有 drivers.xml 说明用户改过，不覆盖
if [ ! -f "\${cfg_dir}/drivers.xml" ] && [ -f "${INSTALL_PATH}/custom-drivers.xml" ]; then
  cp -f "${INSTALL_PATH}/custom-drivers.xml" "\${cfg_dir}/drivers.xml" 2>/dev/null || true
fi
exec "${INSTALL_PATH}/dbeaver" -data "\${DBEAVER_DATA}/workspace" "\$@"
EOF
  chmod +x "${INSTALL_PATH}/dbeaver.sh"
  ln -sfn "${INSTALL_PATH}/dbeaver.sh" /deployment/bin/dbeaver

  # Desktop entry (optional, for XFCE menus)
  mkdir -p /usr/share/applications
  cat > /usr/share/applications/dbeaver.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=DBeaver CE
Comment=Universal Database Manager
Exec=/deployment/bin/dbeaver
Icon=${INSTALL_PATH}/dbeaver.png
Terminal=false
Categories=Development;Database;
EOF

  # 预置 workspace 配置目录（data 被 volume 覆盖时由 dbeaver.sh 再补）
  mkdir -p "${DBEAVER_DATA}/workspace/.metadata/.config"
  cp -f "${INSTALL_PATH}/maven-repositories.xml" "${DBEAVER_DATA}/workspace/.metadata/.config/"
  # 自定义驱动（Redis 等）。DBeaver 重新保存 drivers.xml 时会保留 custom 驱动
  if [ -f "${INSTALL_PATH}/custom-drivers.xml" ]; then
    cp -f "${INSTALL_PATH}/custom-drivers.xml" "${DBEAVER_DATA}/workspace/.metadata/.config/drivers.xml"
  fi

  cat > "${INSTALL_PATH}/README.md" <<'EOF'
# DBeaver CE (COPY-friendly)

镜像预置了常用数据库的 JDBC 驱动（构建期从阿里云 Maven 拉取），缓存目录：

    /deployment/software/dbeaver/data/DBeaverData/drivers/maven/aliyun/

MySQL / MariaDB / PostgreSQL / Oracle / SQL Server / SQLite / H2 / ClickHouse /
StarRocks / Doris / TiDB / IoTDB / DuckDB / Hive / DB2 / Snowflake / Greenplum /
Firebird，以及达梦 / 人大金仓 / GBase 8s / OceanBase / 崖山 / 华为 GaussDB。版本号直接取自
当前 DBeaver 的驱动定义，所以每次重建镜像都会跟随 DBeaver 新版本自动更新；
含传递依赖和 .pom，运行期无需联网即可识别。

"识别"靠的是构建期生成的 `<workspace>/.metadata/.config/drivers.xml`
（安装目录里的 `custom-drivers.xml`）：其中为每个已预取库记录了 `<file>` 条目。
DBeaver 判断驱动是否齐全时读的是这份记录，而不是缓存目录——只把 jar 放进缓存、
没有记录的话，首次连接仍会弹"下载驱动文件"对话框。DBeaver 自己保存配置时也是这个格式
（`${drivers_home}/...`）。H2 / DuckDB / SQL Server 等驱动定义里的 license 直链
（`raw.githubusercontent.com`）也一并预取；构建网络拿不到时会写成 `disabled="true"`
而不会卡住构建，不影响连接。自定义驱动（Redis）也写在同一份文件里。

只有在这些条件不满足时才会重新联网：drivers.xml 被删（首次启动会自动补回）、
缓存文件被删、或在「驱动管理器」里手动点"下载/更新"。因此定义为
`RELEASE` / `[LATEST]` 的驱动（SQLite、DuckDB、TiDB、IoTDB、崖山）只要记录齐全，
运行期同样不会去查 Maven 元数据。

注意：启动器只在 drivers.xml **不存在**时补一份，不会覆盖已有文件（避免冲掉你手改的
驱动）。如果挂载的 data 卷来自旧镜像、里面已经有一份不带预取记录的 drivers.xml，
升级后想用上新的预取记录，删掉 `<workspace>/.metadata/.config/drivers.xml` 再启动即可。

GaussDB（openGauss）的驱动定义是华为云 https 直链（gsjdbc4），不是 Maven 坐标，
按 DBeaver 的远程库规则缓存在：

    /deployment/software/dbeaver/data/DBeaverData/drivers/remote/repository/maven/huaweicloudsdk/gsjdbc4/gsjdbc4/1.1/gsjdbc4-1.1.jar

## Redis

DBeaver CE 官方**不带 Redis 驱动**（Redis 只在 DBeaver 付费版本 Lite/Enterprise/Ultimate 里支持）。
镜像改用社区 JDBC 驱动 dbVisitor 预置了一个自定义驱动，位于「Generic JDBC」连接类型下：

    驱动名: Redis
    驱动类: net.hasor.dbvisitor.driver.JdbcDriver
    URL:    jdbc:dbvisitor:jedis://{host}:{port}?database={database}

驱动包是自包含的 `jdbc-redis-<version>-alone.jar`（含 jedis / commons-pool2），位于
`drivers/remote/maven2/net/hasor/jdbc-redis/...`；版本在构建时取 Maven 最新。
自定义驱动配置写在 `<workspace>/.metadata/.config/drivers.xml`，首次启动自动补上
（如果你自己改过 drivers.xml 就不会覆盖）。这是社区驱动，支持浏览/查询等基本操作，
不等同于付费版的 Redis 支持，遇到协议细节问题请以 dbVisitor 文档为准。

## RabbitMQ

DBeaver **无法连接 RabbitMQ**：RabbitMQ 是 AMQP 消息队列，不是 SQL 数据库，
没有 JDBC 驱动，DBeaver 也没有对应插件。管理请用 RabbitMQ Management UI
（默认 15672 端口）或 `rabbitmqadmin`；Python 侧用 `pika` / `aio-pika`。

## 下载更多 / 更新驱动

「数据库 → 驱动管理器」选数据库 →「库 → 下载/更新」。Maven 默认仓库已配置为
阿里云（`<workspace>/.metadata/.config/maven-repositories.xml`，id=aliyun），
Maven Central 作为兜底。

## 内网 / 离线部署

1. 缓存整个 `/deployment/software/dbeaver/data/DBeaverData/drivers` 目录即可带走；
   或直接挂载同一 data 卷：`-v /host/dbeaver-data:/deployment/software/dbeaver/data`。
2. 属主与容器运行用户（PUID/PGID）保持一致。
3. DBeaver 版本保持一致；跨版本驱动定义会变，缓存可能重新下载。
4. 注意：定义为 `RELEASE` / `[LATEST]`（不带固定版本号）的驱动（如 SQLite、DuckDB、
   TiDB、IoTDB、崖山）在 `drivers.xml` 里已有 `<file>` 记录，完全断网也能用；
   删掉 drivers.xml 或缓存再启动时才会退化为需要联网/手动指定版本。

## 重新预取

    DBEAVER_DRIVER_CACHE=/deployment/software/dbeaver/data/DBeaverData/drivers/maven/aliyun \
    DBEAVER_DRIVERS_HOME=/deployment/software/dbeaver/data/DBeaverData/drivers \
    DBEAVER_CUSTOM_DRIVERS_OUT=/deployment/software/dbeaver/custom-drivers.xml \
      python3 /deployment/software/dbeaver/prefetch-drivers.py

驱动白名单用 `DBEAVER_DRIVER_IDS=mysql8,postgres-jdbc,...` 覆盖
（可选 driver id 见 plugins/org.jkiss.dbeaver.ext.*.jar 里的 plugin.xml）。

## COPY 到其他镜像时

```dockerfile
COPY --from=<dbeaver-image> /deployment/software/dbeaver /deployment/software/dbeaver
COPY --from=<dbeaver-image> /deployment/bin/dbeaver /deployment/bin/dbeaver
```

运行时依赖 `libwebkit2gtk-4.1-0`、`at-spi2-core`、`python3`（重新预取用），
目标镜像里也要装。
EOF

  # 桌面会话用 sam 启动；workspace/驱动缓存必须可写
  chown -R sam:sam "${INSTALL_PATH}"
}

autoExecuteFunc setEnv installDeps installDBeaver downloadDrivers initConfig
