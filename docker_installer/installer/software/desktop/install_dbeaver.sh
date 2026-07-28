#!/bin/bash
###
 # Install DBeaver CE under /deployment/software/dbeaver and prefetch common JDBC drivers.
 # Layer layout (COPY-friendly):
 #   /deployment/software/dbeaver/           # app + bundled JRE
 #   /deployment/software/dbeaver/drivers/   # mysql|mariadb|postgresql|oracle|dameng|sqlserver|sqlite
 #   /deployment/software/dbeaver/data/      # DBeaverData (optional offline maven cache)
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
  export DRIVERS_PATH="${INSTALL_PATH}/drivers"
  export DBEAVER_DATA="${INSTALL_PATH}/data"
  export MAVEN_CENTRAL_PRIMARY="${MAVEN_CENTRAL_PRIMARY:-https://maven.aliyun.com/repository/central}"
  export MAVEN_CENTRAL_FALLBACK="${MAVEN_CENTRAL_FALLBACK:-https://repo1.maven.org/maven2}"

  # App version (override with DBEAVER_PIN_VERSION=26.1.3)
  DBEAVER_VERSION="$(resolve_github_latest_tag dbeaver/dbeaver DBEAVER_PIN_VERSION)" || return 1
  export DBEAVER_VERSION

  # JDBC pins (override individually when needed)
  export MYSQL_JDBC_VERSION="${MYSQL_JDBC_VERSION:-9.1.0}"
  export MARIADB_JDBC_VERSION="${MARIADB_JDBC_VERSION:-3.5.1}"
  export POSTGRES_JDBC_VERSION="${POSTGRES_JDBC_VERSION:-42.7.5}"
  export ORACLE_JDBC_VERSION="${ORACLE_JDBC_VERSION:-23.6.0.24.10}"
  export MSSQL_JDBC_VERSION="${MSSQL_JDBC_VERSION:-12.8.1.jre11}"
  export SQLITE_JDBC_VERSION="${SQLITE_JDBC_VERSION:-3.47.2.0}"
  export DAMENG_JDBC_VERSION="${DAMENG_JDBC_VERSION:-10.10.0.4}"

  echo "Using DBeaver CE ${DBEAVER_VERSION} (${TARGET_ARCH})"
}

# Download a Maven artifact jar into dest_dir (filename kept).
# Usage: maven_download <groupId> <artifactId> <version> <dest_dir> [jar_name]
maven_download(){
  local group_id="$1"
  local artifact_id="$2"
  local version="$3"
  local dest_dir="$4"
  local jar_name="${5:-${artifact_id}-${version}.jar}"
  local group_path="${group_id//.//}"
  local rel="${group_path}/${artifact_id}/${version}/${artifact_id}-${version}.jar"
  local dest="${dest_dir}/${jar_name}"
  local url

  mkdir -p "${dest_dir}"
  if [ -s "${dest}" ]; then
    echo "skip existing ${dest}"
    return 0
  fi

  for base in "${MAVEN_CENTRAL_PRIMARY}" "${MAVEN_CENTRAL_FALLBACK}"; do
    url="${base}/${rel}"
    echo "download ${url}"
    if wget -q --timeout=60 -O "${dest}.partial" "${url}"; then
      mv "${dest}.partial" "${dest}"
      echo "saved ${dest}"
      return 0
    fi
    rm -f "${dest}.partial"
  done

  echo "ERROR: failed to download ${group_id}:${artifact_id}:${version}" >&2
  return 1
}

# Place jar into DBeaver maven-central cache layout (helps built-in drivers find it offline).
# Usage: link_into_dbeaver_maven_cache <groupId> <artifactId> <version> <jar_path>
link_into_dbeaver_maven_cache(){
  local group_id="$1"
  local artifact_id="$2"
  local version="$3"
  local jar_path="$4"
  local group_path="${group_id//.//}"
  local cache_dir="${DBEAVER_DATA}/drivers/maven/maven-central/${group_path}/${artifact_id}/${version}"
  local cache_jar="${cache_dir}/${group_id}.${artifact_id}-${version}.jar"

  mkdir -p "${cache_dir}"
  if [ ! -e "${cache_jar}" ]; then
    ln -sf "${jar_path}" "${cache_jar}" 2>/dev/null || cp -f "${jar_path}" "${cache_jar}"
  fi
}

installDeps(){
  # noble-desktop 已有 gtk/X/gl/wqy 字体；仅补实测缺失项
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends libwebkit2gtk-4.1-0 at-spi2-core \
    || apt-get install -y --no-install-recommends at-spi2-core || true
  apt-get clean -y
  rm -rf /var/lib/apt/lists/*
}

installDBeaver(){
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

  tar -xzf "${tmp}" -C /deployment/software
  rm -f "${tmp}"

  # Official tarball extracts to ./dbeaver
  if [ -d /deployment/software/dbeaver ] && [ "${INSTALL_PATH}" != /deployment/software/dbeaver ]; then
    :
  elif [ -d /deployment/software/dbeaver ]; then
    :
  else
    echo "Unexpected archive layout under /deployment/software" >&2
    ls -la /deployment/software >&2
    return 1
  fi

  # Normalize path name (tarball already uses "dbeaver")
  if [ ! -x "${INSTALL_PATH}/dbeaver" ]; then
    echo "dbeaver binary missing in ${INSTALL_PATH}" >&2
    return 1
  fi

  mkdir -p "${DRIVERS_PATH}" "${DBEAVER_DATA}" /deployment/bin
  ln -sfn "${INSTALL_PATH}/dbeaver" /deployment/bin/dbeaver

  write_cont_env DBEAVER_VERSION "${DBEAVER_VERSION}"
  write_cont_env DBEAVER_HOME "${INSTALL_PATH}"
  write_cont_env DBEAVER_DRIVERS "${DRIVERS_PATH}"
  write_cont_env DBEAVER_DATA "${DBEAVER_DATA}"

  # Persist for merge_and_save_env / child images
  {
    echo "export DBEAVER_HOME=${INSTALL_PATH}"
    echo "export DBEAVER_DRIVERS=${DRIVERS_PATH}"
    echo "export DBEAVER_DATA=${DBEAVER_DATA}"
    echo "export DBEAVER_VERSION=${DBEAVER_VERSION}"
    echo "export PATH=${INSTALL_PATH}:/deployment/bin:\$PATH"
  } >> /etc/environment
}

downloadDrivers(){
  local jar

  # MySQL
  maven_download com.mysql mysql-connector-j "${MYSQL_JDBC_VERSION}" "${DRIVERS_PATH}/mysql" || return 1
  jar="${DRIVERS_PATH}/mysql/mysql-connector-j-${MYSQL_JDBC_VERSION}.jar"
  link_into_dbeaver_maven_cache com.mysql mysql-connector-j "${MYSQL_JDBC_VERSION}" "${jar}"

  # MariaDB
  maven_download org.mariadb.jdbc mariadb-java-client "${MARIADB_JDBC_VERSION}" "${DRIVERS_PATH}/mariadb" || return 1
  jar="${DRIVERS_PATH}/mariadb/mariadb-java-client-${MARIADB_JDBC_VERSION}.jar"
  link_into_dbeaver_maven_cache org.mariadb.jdbc mariadb-java-client "${MARIADB_JDBC_VERSION}" "${jar}"

  # PostgreSQL
  maven_download org.postgresql postgresql "${POSTGRES_JDBC_VERSION}" "${DRIVERS_PATH}/postgresql" || return 1
  jar="${DRIVERS_PATH}/postgresql/postgresql-${POSTGRES_JDBC_VERSION}.jar"
  link_into_dbeaver_maven_cache org.postgresql postgresql "${POSTGRES_JDBC_VERSION}" "${jar}"

  # Oracle (ojdbc11)
  maven_download com.oracle.database.jdbc ojdbc11 "${ORACLE_JDBC_VERSION}" "${DRIVERS_PATH}/oracle" || return 1
  jar="${DRIVERS_PATH}/oracle/ojdbc11-${ORACLE_JDBC_VERSION}.jar"
  link_into_dbeaver_maven_cache com.oracle.database.jdbc ojdbc11 "${ORACLE_JDBC_VERSION}" "${jar}"

  # SQL Server
  maven_download com.microsoft.sqlserver mssql-jdbc "${MSSQL_JDBC_VERSION}" "${DRIVERS_PATH}/sqlserver" || return 1
  jar="${DRIVERS_PATH}/sqlserver/mssql-jdbc-${MSSQL_JDBC_VERSION}.jar"
  link_into_dbeaver_maven_cache com.microsoft.sqlserver mssql-jdbc "${MSSQL_JDBC_VERSION}" "${jar}"

  # SQLite
  maven_download org.xerial sqlite-jdbc "${SQLITE_JDBC_VERSION}" "${DRIVERS_PATH}/sqlite" || return 1
  jar="${DRIVERS_PATH}/sqlite/sqlite-jdbc-${SQLITE_JDBC_VERSION}.jar"
  link_into_dbeaver_maven_cache org.xerial sqlite-jdbc "${SQLITE_JDBC_VERSION}" "${jar}"

  # Dameng（达梦）— Maven 无包时可设 DAMENG_JDBC_URL 指向 DmJdbcDriver18.jar
  mkdir -p "${DRIVERS_PATH}/dameng"
  if [ -n "${DAMENG_JDBC_URL:-}" ]; then
    wget -q --timeout=60 -O "${DRIVERS_PATH}/dameng/DmJdbcDriver18.jar" "${DAMENG_JDBC_URL}" || return 1
  elif maven_download com.dameng DmJdbcDriver18 "${DAMENG_JDBC_VERSION}" "${DRIVERS_PATH}/dameng" DmJdbcDriver18.jar; then
    :
  else
    echo "WARN: Dameng JDBC not found; set DAMENG_JDBC_URL to provide DmJdbcDriver18.jar" >&2
  fi
  if [ -s "${DRIVERS_PATH}/dameng/DmJdbcDriver18.jar" ]; then
    link_into_dbeaver_maven_cache com.dameng DmJdbcDriver18 "${DAMENG_JDBC_VERSION}" \
      "${DRIVERS_PATH}/dameng/DmJdbcDriver18.jar"
  fi

  # Manifest for consumers that COPY this layer
  {
    echo "# DBeaver JDBC drivers prefetch manifest"
    echo "DBEAVER_VERSION=${DBEAVER_VERSION}"
    echo "DRIVERS_PATH=${DRIVERS_PATH}"
    find "${DRIVERS_PATH}" -type f -name '*.jar' | sort | while read -r f; do
      echo "JAR=$(basename "$(dirname "$f")")/$(basename "$f")"
    done
  } > "${DRIVERS_PATH}/MANIFEST.txt"

  echo "Drivers ready:"
  cat "${DRIVERS_PATH}/MANIFEST.txt"
}

initConfig(){
  # Launcher wrapper: isolate data dir so the whole tree is relocatable / COPY-able
  cat > "${INSTALL_PATH}/dbeaver.sh" <<EOF
#!/bin/bash
export DBEAVER_HOME="${INSTALL_PATH}"
export DBEAVER_DRIVERS="${DRIVERS_PATH}"
export DBEAVER_DATA="\${DBEAVER_DATA:-${DBEAVER_DATA}}"
# Keep Eclipse/DBeaver user data inside the software tree (not \$HOME), so child images can COPY one layer.
mkdir -p "\${DBEAVER_DATA}"
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

  # Seed a default .dbeaver configuration directory for first-run hints
  mkdir -p "${DBEAVER_DATA}/workspace/.metadata"
  cat > "${INSTALL_PATH}/README.drivers.md" <<EOF
# DBeaver layer (COPY-friendly)

This image installs apt gaps (libwebkit2gtk-4.1-0, at-spi2-core) in-place.
If you only COPY the software tree into another image, install those packages there too.

\`\`\`dockerfile
COPY --from=<dbeaver-image> /deployment/software/dbeaver /deployment/software/dbeaver
COPY --from=<dbeaver-image> /deployment/bin/dbeaver /deployment/bin/dbeaver
\`\`\`

Drivers: \\\`${DRIVERS_PATH}\\\` (mysql/mariadb/postgresql/oracle/sqlserver/sqlite/dameng)
EOF
}

autoExecuteFunc setEnv installDeps installDBeaver downloadDrivers initConfig
