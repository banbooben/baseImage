#!/bin/bash
###
 # @Author: shangyameng
 # @Email: shangyameng@aliyun.com
 # @Date: 2025-04-22 12:17:54
 # @LastEditTime: 2025-04-22 13:18:50
 # @FilePath: /baseImage/docker_installer/installer/middleware/hive/install_hive.sh
###

source /deployment/scripts/common.sh

setEnv(){
  #
  export JAVA_HOME=/deployment/openjdk
  export HADOOP_HOME=/deployment/hadoop
  export HIVE_HOME=/deployment/hive
  export PATH=${HIVE_HOME}/bin:${HADOOP_HOME}/bin:${HADOOP_HOME}/sbin:${JAVA_HOME}/bin:$PATH
  export HADOOP_SERIES=3.4
  HADOOP_VERSION="$(resolve_eol_latest_version apache-hadoop "$HADOOP_SERIES" HADOOP_PIN_VERSION)" || return 1
  export HADOOP_VERSION
  export HIVE_SERIES=4
  HIVE_VERSION="$(resolve_apache_hive_latest_version "$HIVE_SERIES" HIVE_PIN_VERSION)" || return 1
  export HIVE_VERSION
  export JAVA_VERSION=11

  export START_USER=hadoop
  export HDFS_NAMENODE_USER=hadoop
  export HDFS_DATANODE_USER=hadoop
  export HDFS_SECONDARYNAMENODE_USER=hadoop
  export RECREATE_HDFS_FOLDER=true
  echo "Using Hive ${HIVE_VERSION} (series ${HIVE_SERIES}), Hadoop ${HADOOP_VERSION}"

}

initHiveConfig(){
  ensure_password HIVE_DB_PASSWORD
cat > ${HIVE_HOME}/conf/hive-site.xml <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<configuration>
  <!-- 元数据库JDBC 连接配置 -->
  <property><name>javax.jdo.option.ConnectionURL</name><value>jdbc:mariadb://localhost:3306/hive_metastore?createDatabaseIfNotExist=true</value></property>
  <property><name>javax.jdo.option.ConnectionDriverName</name><value>org.mariadb.jdbc.Driver</value></property>
  <property><name>javax.jdo.option.ConnectionUserName</name><value>hadoop</value></property>
  <property><name>javax.jdo.option.ConnectionPassword</name><value>${HIVE_DB_PASSWORD}</value></property>

  <!-- Hive Metastore 配置 -->
  <property><name>datanucleus.connectionPoolingType</name><value>DBCP</value></property>
  <property><name>hive.server2.authentication</name><value>NONE</value></property>
  <property><name>hive.metastore.warehouse.dir</name><value>/user/hive/warehouse</value></property>
  <property><name>hive.server2.thrift.port</name><value>10000</value></property>
  <property><name>hive.server2.thrift.bind.host</name><value>0.0.0.0</value></property>
  <property><name>hive.metastore.schema.verification</name><value>false</value></property>
  <property><name>datanucleus.schema.autoCreateAll</name><value>true</value></property>
  <property><name>hive.server2.enable.doAs</name><value>true</value></property>
</configuration>
EOF
  unset HIVE_DB_PASSWORD
}

installHive(){

  wget -q https://downloads.apache.org/hive/hive-${HIVE_VERSION}/apache-hive-${HIVE_VERSION}-bin.tar.gz || { echo "Failed to download Hive. Exiting."; exit 1; }
  tar -xzf apache-hive-${HIVE_VERSION}-bin.tar.gz
  mv apache-hive-${HIVE_VERSION}-bin ${HIVE_HOME}
  rm -f apache-hive-${HIVE_VERSION}-bin.tar.gz
  cd ${HIVE_HOME}/lib
  wget https://downloads.mariadb.com/Connectors/java/connector-java-3.1.4/mariadb-java-client-3.1.4.jar

  initHiveConfig
  mkdir -p ${HIVE_HOME}/logs
  chmod +x ${HIVE_HOME}/bin/schematool

  echo "export JAVA_HOME=${JAVA_HOME}" >> ${HIVE_HOME}/hive-env.xml
  echo "export HADOOP_HOME=${HADOOP_HOME}" >> ${HIVE_HOME}/conf/hive-env.sh
  echo "export HIVE_HOME=${HIVE_HOME}" >> ${HIVE_HOME}/hive-env.xml
  echo "export HIVE_CONF_DIR=${HIVE_HOME}/conf" >> ${HIVE_HOME}/hive-env.xml

  echo "export HDFS_DATANODE_USER=hadoop" >> ${HIVE_HOME}/hive-env.xml
  echo "export HDFS_SECONDARYNAMENODE_USER=hadoop" >> ${HIVE_HOME}/hive-env.xml

}

InitHiveStartSCript(){

  echo "#!/bin/bash
# 打印使用说明
usage() {
  echo \"Usage: \$0 {metastore|hiveserver2|cli}\"
  exit 1
}

# 初始化 Hive 的元存储
init_metastore() {
  case \"\${METASTORE_TYPE:-derby}\" in
    mysql)
      echo \"Initializing Hive metastore with MySQL...\"
      schematool -initSchema -dbType mysql
      ;;
    derby)
      echo \"Initializing Hive metastore with Derby (default)...\"
      schematool -initSchema -dbType derby
      ;;
    *)
      echo \"Invalid metastore type \${METASTORE_TYPE} exiting\"
      exit 1
  esac
}

# 启动 Hive Metastore 服务
start_metastore() {
  echo \"Starting Hive Metastore...\"
  export HIVE_CONF_DIR=\${HIVE_HOME}/conf
  nohup \${HIVE_HOME}/bin/hive --service metastore > \${HIVE_HOME}/logs/metastore.log 2>&1 &
  echo \"Hive Metastore started. Logs: \${HIVE_HOME}/logs/metastore.log\"
}

# 启动 HiveServer2 服务
start_hiveserver2() {
  echo \"Starting HiveServer2...\"
  export HIVE_CONF_DIR=\${HIVE_HOME}/conf
  \${HIVE_HOME}/bin/hiveserver2
}

# 启动 Hive CLI
start_cli() {
  echo \"Starting Hive CLI...\"
  \${HIVE_HOME}/bin/hive
}

# 检查输入参数
if [ \$# -ne 1 ]; then
  usage
fi

# 初始化元存储
init_metastore

case \$1 in
  metastore)
    start_metastore
    ;;
  hiveserver2)
    start_hiveserver2
    ;;
  cli)
    start_cli
    ;;
  *)
    usage
    ;;
esac
" > ${HIVE_HOME}/start.sh

  chmod +x ${HIVE_HOME}/start.sh

}

initS6Config(){
  write_cont_env HIVE_VERSION "${HIVE_VERSION}"
  write_cont_env HIVE_SERIES "${HIVE_SERIES}"
  write_cont_env HADOOP_VERSION "${HADOOP_VERSION}"
  write_cont_env HADOOP_SERIES "${HADOOP_SERIES}"

  register_s6_longrun_cmd hive-metastore \
    "sleep 5; exec bash ${HIVE_HOME}/start.sh metastore" \
    hadoop
  register_s6_longrun_cmd hive \
    "sleep 10; exec bash ${HIVE_HOME}/start.sh hiveserver2" \
    hadoop
  register_s6_dependency hive hive-metastore
  register_s6_dependency hive-metastore sshd
  : > /etc/s6-overlay/s6-rc.d/user/contents.d/sshd
}

lastInstallHive(){
  chown -R ${START_USER}:${START_USER} ${HIVE_HOME}

}

autoExecuteFunc setEnv installHive InitHiveStartSCript initS6Config lastInstallHive
