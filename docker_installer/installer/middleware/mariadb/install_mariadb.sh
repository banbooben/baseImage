#!/bin/bash
source /deployment/scripts/common.sh

setEnv(){
  # 设置环境变量
  export INSTALL_PATH=/deployment/mariadb
  export PATH=${INSTALL_PATH}/bin:$PATH
  export LD_LIBRARY_PATH=${INSTALL_PATH}/lib:$LD_LIBRARY_PATH

  # MariaDB LTS series (major.minor), resolve latest patch
  export MARIADB_SERIES=11.4
  MARIADB_VERSION="$(resolve_eol_latest_version mariadb "$MARIADB_SERIES" MARIADB_PIN_VERSION)" || return 1
  export MARIADB_VERSION
  echo "Using MariaDB ${MARIADB_VERSION} (series ${MARIADB_SERIES})"
  echo "Configuring environment variables..."
  echo "export PATH=${INSTALL_PATH}/bin:\$PATH" >> /etc/environment
  source /etc/environment

}

beforeInstallMariadb(){
  # 创建用户
  #  create_user mysql --sudo --nopasswd --sshkey
  echo "Creating user mysql..."

}

installMariaDB() {

  # 下载并解压 MariaDB 二进制文件
  echo "Downloading MariaDB ${MARIADB_VERSION}..."
  wget https://mirrors.aliyun.com/mariadb/mariadb-${MARIADB_VERSION}/bintar-linux-systemd-x86_64/mariadb-${MARIADB_VERSION}-linux-systemd-x86_64.tar.gz
  tar -xvzf mariadb-${MARIADB_VERSION}-linux-systemd-x86_64.tar.gz
  mv mariadb-${MARIADB_VERSION}-linux-systemd-x86_64 ${INSTALL_PATH}
  rm -f mariadb-${MARIADB_VERSION}-linux-systemd-x86_64.tar.gz

}

# 优化配置文件
optimize_config() {
  echo "Optimizing MariaDB configuration..."
  cat > ${INSTALL_PATH}/my.cnf <<EOF
[mysqld]
basedir=/deployment/mariadb
datadir=/deployment/mariadb/data
port=3306
socket=/deployment/mariadb/mysql.sock
user=mysql

# 优化参数
innodb_buffer_pool_size=1G
max_connections=200
query_cache_size=64M
log_error=/deployment/mariadb/logs/mariadb_error.log
EOF
  chown -R mysql:mysql ${INSTALL_PATH}
}

initStartCommand(){
  echo "Generating start.sh script..."
  export START_SCRIPT_PATH=${INSTALL_PATH}/start.sh

  echo '#!/bin/bash

  # Define variables
  INSTALL_PATH=/deployment/mariadb
  MYSQLD_SAFE="/deployment/mariadb/bin/mysqld_safe"
  MYSQL="/deployment/mariadb/bin/mysql"
  DATA_DIR="/deployment/mariadb/data"
  MY_CNF="/deployment/mariadb/my.cnf"

  # Check if the database is initialized
  initialize_database_if_needed() {
    if [ ! -d "${DATA_DIR}/mysql" ]; then
      echo "Database not initialized. Initializing now..."
      /deployment/mariadb/scripts/mysql_install_db --user=mysql --basedir=/deployment/mariadb --datadir=${DATA_DIR}
      chown -R mysql:mysql /deployment/mariadb
    else
      echo "Database already initialized."
    fi
  }

  # Configure root password and create user
  configure_users_if_needed() {
    if [ ! -f "${DATA_DIR}/.user_configured" ]; then
      echo "Configuring root password and creating user..."

      # Start MariaDB temporarily
      ${MYSQLD_SAFE} --defaults-file=${MY_CNF} --skip-networking &
      sleep 5

      # Set root password and create user
      ${MYSQL} -u root <<EOF_SQL

  CREATE DATABASE IF NOT EXISTS ${MYSQL_DATABASE};
  ALTER USER '\''root'\''@'\''localhost'\'' IDENTIFIED BY '\''${MYSQL_ROOT_PASSWORD}'\'';
  FLUSH PRIVILEGES;

  CREATE USER '\''${MYSQL_USER}'\''@'\''%'\'' IDENTIFIED BY '\''${MYSQL_PASSWORD}'\'';
  GRANT ALL PRIVILEGES ON *.* TO '\''${MYSQL_USER}'\''@'\''%'\'' WITH GRANT OPTION;
  FLUSH PRIVILEGES;
  EOF_SQL

      # Stop MariaDB
      pkill -f mysqld
      sleep 5

      # Mark as configured
      touch "${DATA_DIR}/.user_configured"
      echo "User configuration completed."
    else
      echo "User already configured."
    fi
  }

  # Start MariaDB service
  start_service() {
    echo "Starting MariaDB service..."
    ${MYSQLD_SAFE} --defaults-file=${MY_CNF}
  }

  # Main execution
  initialize_database_if_needed
  configure_users_if_needed
  start_service
  ' > ${START_SCRIPT_PATH}

  # Make the script executable
  chmod +x ${START_SCRIPT_PATH}
  echo "start.sh script generated at ${START_SCRIPT_PATH}."
}

initS6Config(){
  write_cont_env MARIADB_VERSION "${MARIADB_VERSION}"
  write_cont_env MARIADB_SERIES "${MARIADB_SERIES}"
  register_s6_longrun_cmd mariadb "exec /bin/bash ${INSTALL_PATH}/start.sh"
}

autoExecuteFunc setEnv beforeInstallMariadb installMariaDB optimize_config initStartCommand initS6Config
