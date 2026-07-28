#!/bin/bash
source /deployment/scripts/common.sh

# Oracle Instant Client: no fixed major in this installer — always use Oracle's latest package.
installOracle(){
  mkdir -p /deployment/oracle
  apt-get install -y --no-install-recommends libaio1t64 libaio1 unzip || \
    apt-get install -y --no-install-recommends libaio1 unzip
  # shellcheck disable=SC2164
  cd /deployment/oracle
  wget --no-check-certificate -O instantclient-basic-linuxx64.zip \
    https://download.oracle.com/otn_software/linux/instantclient/instantclient-basic-linuxx64.zip
  unzip -o /deployment/oracle/instantclient-basic-linuxx64.zip -d /deployment/oracle/
  rm -f /deployment/oracle/instantclient-basic-linuxx64.zip

  IC_DIR="$(find /deployment/oracle -maxdepth 1 -type d -name 'instantclient_*' | sort | tail -n 1)"
  if [ -z "$IC_DIR" ]; then
    echo "Failed to locate extracted Oracle Instant Client directory" >&2
    return 1
  fi
  export ORACLE_INSTANTCLIENT_HOME="$IC_DIR"
  echo "Using Oracle Instant Client at ${ORACLE_INSTANTCLIENT_HOME}"
  write_cont_env ORACLE_INSTANTCLIENT_HOME "${ORACLE_INSTANTCLIENT_HOME}"

  chmod -R 777 /etc/ld.so.conf.d/
  echo "$ORACLE_INSTANTCLIENT_HOME" > /etc/ld.so.conf.d/oracle-instantclient.conf
  ldconfig
  export LD_LIBRARY_PATH=${ORACLE_INSTANTCLIENT_HOME}:$LD_LIBRARY_PATH
  mkdir -p "${ORACLE_INSTANTCLIENT_HOME}/network/admin"
}

autoExecuteFunc installOracle
