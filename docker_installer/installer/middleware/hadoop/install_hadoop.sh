#!/bin/bash
source /deployment/scripts/common.sh

setEnv(){
  #
  export JAVA_HOME=/deployment/openjdk
  export HADOOP_HOME=/deployment/hadoop
  export PATH=${JAVA_HOME}/bin:$PATH
  export PATH=${HADOOP_HOME}/bin:${HADOOP_HOME}/sbin:$PATH
  export HADOOP_SERIES=3.4
  HADOOP_VERSION="$(resolve_eol_latest_version apache-hadoop "$HADOOP_SERIES" HADOOP_PIN_VERSION)" || return 1
  export HADOOP_VERSION
  export START_USER=hadoop
  export HDFS_NAMENODE_USER=hadoop
  export HDFS_DATANODE_USER=hadoop
  export HDFS_SECONDARYNAMENODE_USER=hadoop
  export RECREATE_HDFS_FOLDER=false
  echo "Using Hadoop ${HADOOP_VERSION} (series ${HADOOP_SERIES})"

}

initConfig(){

  mkdir -p ${HADOOP_HOME}/hdfs/namenode
  mkdir -p ${HADOOP_HOME}/hdfs/datanode
  mkdir -p ${HADOOP_HOME}/logs

  echo "
  <configuration>
    <!-- 新增配置：允许hadoop用户代理任意用户和组 -->
    <property><name>hadoop.proxyuser.hadoop.hosts</name><value>*</value></property>
    <property><name>hadoop.proxyuser.hadoop.groups</name><value>*</value></property>

    <!-- 其他配置（如fs.defaultFS） -->
    <property><name>fs.defaultFS</name><value>hdfs://localhost:9000</value></property>
  </configuration>
  " > ${HADOOP_HOME}/etc/hadoop/core-site.xml

  echo "
  <configuration>
    <property><name>dfs.replication</name><value>1</value></property>
    <property><name>dfs.namenode.data.dir</name><value>file:///deployment/hadoop/hdfs/namenode</value></property>
    <property><name>dfs.datanode.data.dir</name><value>file:///deployment/hadoop/hdfs/datanode</value></property>
    <!-- 修改端口为1024以上，避免安全模式用户问题 -->
    <property><name>dfs.datanode.address</name><value>0.0.0.0:50020</value></property>
  </configuration>
  " > ${HADOOP_HOME}/etc/hadoop/hdfs-site.xml

  echo "
  <configuration>
    <property><name>mapreduce.framework.name</name><value>yarn</value></property>
  </configuration>
  " > ${HADOOP_HOME}/etc/hadoop/mapred-site.xml

  echo "
  <configuration>
    <property><name>yarn.nodemanager.bind-host</name><value>0.0.0.0</value></property>
    <property><name>yarn.nodemanager.aux-services</name><value>mapreduce_shuffle</value></property>
    <property>
      <name>yarn.nodemanager.env-whitelist</name>
      <value>JAVA_HOME,HADOOP_COMMON_HOME,HADOOP_HDFS_HOME,HADOOP_CONF_DIR,CLASSPATH_PREPEND_DISTCACHE,HADOOP_YARN_HOME,HADOOP_MAPRED_HOME</value>
    </property>
  </configuration>
  " > ${HADOOP_HOME}/etc/hadoop/yarn-site.xml

  echo "
export JAVA_HOME=${JAVA_HOME}
  " > ${HADOOP_HOME}/etc/hadoop/hadoop-env.sh


}

installHadoop(){
  wget -q https://downloads.apache.org/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz || { echo "Failed to download Hadoop. Exiting."; exit 1; }
  tar -xzf hadoop-${HADOOP_VERSION}.tar.gz
  mv hadoop-${HADOOP_VERSION} ${HADOOP_HOME}
  rm -f hadoop-${HADOOP_VERSION}.tar.gz
  initConfig
  chown -R ${START_USER}:${START_USER} ${HADOOP_HOME}
}

initHadoopStartScript(){
  echo '
  #!/bin/bash

  # Start SSH service if not already running
  if ! pgrep -x "sshd" > /dev/null; then
    echo "Starting SSH service..."
    sudo service ssh start
  else
    echo "SSH service is already running."
  fi

  # Check if HDFS initialization is required
  if [ "${RECREATE_HDFS_FOLDER}" = "true" ]; then
    if [ ! -d "${HADOOP_HOME}/hdfs/namenode/current" ] || [ -z "$(ls -A ${HADOOP_HOME}/hdfs/namenode/current 2>/dev/null)" ]; then
      echo "HDFS namenode 未初始化，执行格式化操作..."
      echo "Y" | hdfs namenode -format
    else
      echo "HDFS namenode is already formatted."
    fi
  else
    echo "HDFS initialization is skipped as per environment variable."
  fi

  # Start Hadoop services
  echo "Starting Hadoop Distributed File System (DFS)..."
  bash start-dfs.sh

  # Create Hive warehouse directory in HDFS
  echo "Creating Hive warehouse directory in HDFS..."
  hdfs dfs -mkdir -p /user/hive/warehouse
  hdfs dfs -chmod -R 777 /user/hive/warehouse

  echo "Starting Hadoop YARN..."
  bash start-yarn.sh
  jps
  ' > ${HADOOP_HOME}/start.sh
  chmod +x ${HADOOP_HOME}/start.sh

}


initS6Config(){
  write_cont_env HADOOP_VERSION "${HADOOP_VERSION}"
  write_cont_env HADOOP_SERIES "${HADOOP_SERIES}"
  register_s6_longrun_cmd hadoop \
    "bash ${HADOOP_HOME}/start.sh; exec tail -f /dev/null" \
    hadoop
  register_s6_dependency hadoop sshd
  : > /etc/s6-overlay/s6-rc.d/user/contents.d/sshd
}

lastInstallHadoop(){
  chown -R ${START_USER}:${START_USER} ${HADOOP_HOME}
  chmod +x ${HADOOP_HOME}/start.sh
}


autoExecuteFunc setEnv installHadoop initHadoopStartScript initS6Config lastInstallHadoop
