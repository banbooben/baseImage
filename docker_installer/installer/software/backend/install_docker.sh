#!/bin/bash
source /deployment/scripts/common.sh

# Install latest docker-ce from apt (no major series pin).
initConfigFile(){
  touch /etc/docker/daemon.json
  echo '
{
    "registry-mirrors": [
        "https://1l41wjhf.mirror.aliyuncs.com"
    ],
    "storage-driver": "overlay2",
    "default-address-pools": [
        {"base": "172.17.0.0/12", "size": 24}
    ]
}
' > /etc/docker/daemon.json

}

installDocker(){
  install -m 0755 -d /etc/apt/keyrings
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release software-properties-common
  curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  apt-get autoremove -y software-properties-common ca-certificates gnupg
}

autoExecuteFunc installDocker initConfigFile
