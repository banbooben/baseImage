#!/bin/bash
# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
RESET='\033[0m'
BOLD='\033[1m'

# Ensure a password env var is set; generate a random value if missing.
# Usage: ensure_password ROOT_PASSWORD
ensure_password() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf -v "$name" '%s' "$(openssl rand -base64 18 | tr -d '=+/')"
    export "$name"
    echo -e "${CYAN}提示: ${name} 未提供，已生成随机密码${RESET}" >&2
  fi
}

beforeInstall(){
  echo "sed apt sources list"
  sed -i "s#http://ports.ubuntu.com/#http://mirrors.aliyun.com/#g" /etc/apt/sources.list.d/ubuntu.sources
  ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

  echo "set pip sources"
  mkdir -p ~/.pip
  echo "[global]
     index-url = https://mirrors.aliyun.com/pypi/simple/" > ~/.pip/pip.conf
  apt-get update

}

# Shared HTTP GET for installer version-resolve helpers.
_installer_http_get() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
  else
    return 1
  fi
}

# Resolve latest patch for a Python series (e.g. 3.12 -> 3.12.13).
# Override with PYTHON_PIN_VERSION=3.12.10 to pin a specific release.
resolve_python_latest_version() {
  local series="$1"
  local latest=""

  if [ -n "${PYTHON_PIN_VERSION:-}" ]; then
    echo "$PYTHON_PIN_VERSION"
    return 0
  fi

  latest="$(_installer_http_get "https://endoflife.date/api/python/${series}.json" 2>/dev/null \
    | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1)"

  if [ -z "$latest" ]; then
    local listing
    listing="$(_installer_http_get "https://www.python.org/ftp/python/" 2>/dev/null || true)"
    latest="$(printf '%s\n' "$listing" \
      | grep -oE "${series}\.[0-9]+" \
      | sort -t. -k3 -n \
      | tail -n 1)"
  fi

  if [ -z "$latest" ]; then
    echo "Failed to resolve latest Python version for series ${series}" >&2
    return 1
  fi

  echo "$latest"
}

# Resolve latest OpenJDK update for a major version (e.g. 11 -> 11.0.31+11).
# Override with JAVA_PIN_VERSION=11.0.26+4 to pin a specific release.
resolve_openjdk_latest_version() {
  local major="$1"
  local latest=""
  local next_major=$((major + 1))

  if [ -n "${JAVA_PIN_VERSION:-}" ]; then
    echo "$JAVA_PIN_VERSION"
    return 0
  fi

  latest="$(_installer_http_get "https://api.adoptium.net/v3/info/release_versions?version=%5B${major}%2C${next_major}%29&release_type=ga&page_size=1&sort_method=DATE&sort_order=DESC" 2>/dev/null \
    | sed -n 's/.*"openjdk_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1)"
  latest="${latest%-LTS}"

  if [ -z "$latest" ]; then
    echo "Failed to resolve latest OpenJDK version for major ${major}" >&2
    return 1
  fi

  echo "$latest"
}

# Resolve latest for an endoflife.date product cycle (e.g. redis/7.4 -> 7.4.9).
# Optional pin: pass pin via env named by 3rd arg, or VERSION_PIN.
resolve_eol_latest_version() {
  local product="$1"
  local cycle="$2"
  local pin_env="${3:-VERSION_PIN}"
  local pin_value=""
  local latest=""

  eval "pin_value=\${${pin_env}:-}"
  if [ -n "$pin_value" ]; then
    echo "$pin_value"
    return 0
  fi

  latest="$(_installer_http_get "https://endoflife.date/api/${product}/${cycle}.json" 2>/dev/null \
    | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1)"

  if [ -z "$latest" ]; then
    echo "Failed to resolve latest ${product} version for cycle ${cycle}" >&2
    return 1
  fi

  echo "$latest"
}

# Resolve latest GitHub release tag (strips leading v). Override with VERSION_PIN or 2nd env name.
resolve_github_latest_tag() {
  local repo="$1"
  local pin_env="${2:-VERSION_PIN}"
  local pin_value=""
  local latest=""

  eval "pin_value=\${${pin_env}:-}"
  if [ -n "$pin_value" ]; then
    echo "$pin_value"
    return 0
  fi

  latest="$(_installer_http_get "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\?\([^"]*\)".*/\1/p' \
    | head -n 1)"

  if [ -z "$latest" ]; then
    echo "Failed to resolve latest GitHub release for ${repo}" >&2
    return 1
  fi

  echo "$latest"
}

# Resolve latest Apache Hive version for a series (e.g. 4 or 4.0 -> 4.2.0).
resolve_apache_hive_latest_version() {
  local series="$1"
  local pin_env="${2:-HIVE_PIN_VERSION}"
  local pin_value=""
  local latest=""
  local listing=""

  eval "pin_value=\${${pin_env}:-}"
  if [ -n "$pin_value" ]; then
    echo "$pin_value"
    return 0
  fi

  listing="$(_installer_http_get "https://downloads.apache.org/hive/" 2>/dev/null || true)"
  latest="$(printf '%s\n' "$listing" \
    | grep -oE "hive-${series}(\.[0-9]+)+/" \
    | sed 's#hive-##;s#/##' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -n 1)"

  if [ -z "$latest" ]; then
    listing="$(_installer_http_get "https://archive.apache.org/dist/hive/" 2>/dev/null || true)"
    latest="$(printf '%s\n' "$listing" \
      | grep -oE "hive-${series}(\.[0-9]+)+/" \
      | sed 's#hive-##;s#/##' \
      | sort -t. -k1,1n -k2,2n -k3,3n \
      | tail -n 1)"
  fi

  if [ -z "$latest" ]; then
    echo "Failed to resolve latest Apache Hive version for series ${series}" >&2
    return 1
  fi

  echo "$latest"
}

# Write an s6-overlay container env var (/etc/cont-env.d/KEY).
write_cont_env() {
  local key="$1"
  local value="$2"
  mkdir -p /etc/cont-env.d
  printf '%s' "$value" > "/etc/cont-env.d/${key}"
  export "${key}=${value}"
}

# Register an s6-rc longrun service.
# Usage: register_s6_longrun <name> <path-to-run-script-content-file-or-heredoc via stdin not supported>
# Prefer writing run body with register_s6_longrun_cmd.
register_s6_longrun_cmd() {
  local name="$1"
  local run_body="$2"
  local run_user="${3:-}"
  local svc="/etc/s6-overlay/s6-rc.d/${name}"

  mkdir -p "${svc}/dependencies.d" /etc/s6-overlay/s6-rc.d/user/contents.d
  printf 'longrun\n' > "${svc}/type"
  : > "${svc}/dependencies.d/base"
  : > "/etc/s6-overlay/s6-rc.d/user/contents.d/${name}"

  if [ -n "$run_user" ]; then
    local escaped_body
    escaped_body="$(printf '%q' "${run_body}")"
    cat > "${svc}/run" <<EOF
#!/command/with-contenv bash
exec s6-setuidgid ${run_user} bash -lc "${escaped_body}"
EOF
  else
    cat > "${svc}/run" <<EOF
#!/command/with-contenv bash
${run_body}
EOF
  fi
  chmod 0755 "${svc}/run"
}

# Add an s6-rc dependency: service A depends on B.
register_s6_dependency() {
  local name="$1"
  local dep="$2"
  mkdir -p "/etc/s6-overlay/s6-rc.d/${name}/dependencies.d"
  : > "/etc/s6-overlay/s6-rc.d/${name}/dependencies.d/${dep}"
}

endInstall(){
  apt-get autoremove -y
  apt-get clean -y
  apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false
  rm -rf /var/lib/apt/lists/*
}

executeWithRetry() {
  # 执行指定方法并在失败时重试
  # 参数1: 方法名
  # 参数2: 最大重试次数
  local method="$1"
  local max_retries="$2"
  local retry_count=0

  while [ $retry_count -lt $max_retries ]; do
    # 调用传入的方法
    $method

    # 检查方法退出码
    if [ $? -eq 0 ]; then
      echo "方法执行成功"
      break
    else
      echo "方法执行失败"
      # 增加重试计数
      retry_count=$((retry_count + 1))
      if [ $retry_count -lt $max_retries ]; then
        echo "重试 ($retry_count / $max_retries)..."
        # 避免立即重试
        sleep 1
      else
        echo "已达到最大重试次数，终止脚本"
        exit 1
      fi
    fi
  done
}

autoExecuteFunc(){
  local args=($@)
  echo $args
  # 获取参数数量
  local num_args=${#args[@]}

  beforeInstall

  # 遍历参数并逐个执行
  for ((i=0; i<num_args; i++)); do
    echo "start run function $((i+1)): ${args[$i]}"
    executeWithRetry ${args[$i]} 5
  done

  endInstall
  merge_and_save_env

}

node_is_master(){
  # 获取 Swarm 集群节点列表
  node_list=$(docker node ls --format "{{.ID}}:{{.Hostname}}")

  # 存储 manager 节点信息
  manager_nodes=()

  # 遍历节点并筛选 manager
  while IFS= read -r node_info; do
    node_id=$(echo "$node_info" | cut -d ':' -f 1)
    node_hostname=$(echo "$node_info" | cut -d ':' -f 2)
    node_role=$(docker node inspect --format "{{.Spec.Role}}" "$node_id")

    if [ "$node_role" == "manager" ]; then
      manager_nodes+=("$node_hostname")
    fi

  # 初始化标记
  found=false

  # 检查目标主机是否在 manager 列表中
  for item in "${manager_nodes[@]}"; do
    if [ "$item" == "$1" ]; then
      found=true
      break
    fi
  done

  done <<< "$node_list"

  if [ "$found" == true ]; then
    echo "$1 is manager node"
    return 0
  else
    echo "$1 不是管理节点"
    return 1
  fi

}

create_user() {
    local username=""
    local password=""
    local use_sudo=false
    local no_passwd_sudo=false
    local generate_sshkey=false
    local home_dir=""

    # 参数解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sudo) use_sudo=true ;;
            --nopasswd) no_passwd_sudo=true ;;
            --sshkey) generate_sshkey=true ;;
            --home-dir=*) home_dir="${1#*=}" ;;
            --home-dir)
                [[ $# -ge 2 ]] && { home_dir="$2"; shift; } || {
                    echo -e "${RED}Error: --home-dir requires a path${RESET}"
                    return 1
                }
                ;;
            -*)
                echo -e "${YELLOW}警告: 忽略未知选项 '$1'${RESET}"
                ;;
            *)
                if [[ -z "$username" ]]; then
                    username="$1"
                elif [[ -z "$password" ]]; then
                    password="$1"
                else
                    echo -e "${YELLOW}警告: 忽略多余参数 '$1'${RESET}"
                fi
                ;;
        esac
        shift
    done

    # 校验用户名
    if [[ -z "$username" ]]; then
        echo -e "${RED}错误: 未指定用户名${RESET}"
        echo -e "用法: $0 用户名 [密码] [选项]"
        echo -e "选项:"
        echo -e "  --sudo          add user to sudo group"
        echo -e "  --nopasswd      配置免密 sudo"
        echo -e "  --sshkey        generate ssh keypair"
        echo -e "  --home-dir=PATH set user home directory"
        return 1
    fi

    # 检查用户是否已存在
    if id "$username" &>/dev/null; then
        echo -e "${RED}错误: 用户 '$username' 已存在${RESET}"
        return 1
    fi

    # 设置默认家目录
    [[ -z "$home_dir" ]] && home_dir="/deployment/accounts/$username"

    # 未提供密码时自动生成随机密码
    if [[ -z "$password" ]]; then
        password=$(openssl rand -base64 12 | tr -d '=+/')
        echo -e "${CYAN}提示: 已为用户 '$username' 生成随机密码${RESET}"
    fi

    # 创建用户
    echo -e "${BLUE}正在创建用户 '$username'...${RESET}"
    echo -e "家目录位置: ${BOLD}$home_dir${RESET}"

    # 确保父目录存在
    sudo mkdir -p "$(dirname "$home_dir")" || {
        echo -e "${RED}父目录创建失败: $(dirname "$home_dir")${RESET}"
        return 1
    }

    # 创建用户并设置家目录
    if ! sudo useradd -m -d "$home_dir" -s /bin/bash "$username"; then
        echo -e "${RED}User creation failed${RESET}"
        return 1
    fi

    # 设置密码
    echo "$username:$password" | sudo chpasswd || {
        echo -e "${RED}Password setup failed${RESET}"
        sudo userdel -r "$username" 2>/dev/null
        return 1
    }

    # 修复目录权限（useradd -m 可能未设置到预期权限）
    sudo chown -R "$username:$username" "$home_dir"
    sudo chmod 700 "$home_dir"

    # 配置 sudo 权限：仅加组不够——若 /etc/sudoers 缺 %sudo 规则会报「不在 sudoers 中」
    # 因此同时写入 /deployment/accounts/sudoers.d（由 initSudoers 引入）
    if [[ "$use_sudo" == true ]]; then
        echo -e "${BLUE}将用户 '$username' 加入 sudo 组...${RESET}"
        sudo usermod -aG sudo "$username" || {
            echo -e "${RED}加入 sudo 组失败${RESET}"
            return 1
        }

        sudo mkdir -p /deployment/accounts/sudoers.d
        local sudoers_file="/deployment/accounts/sudoers.d/${username}"
        if [[ "$no_passwd_sudo" == true ]]; then
            echo -e "${BLUE}配置免密 sudo...${RESET}"
            echo "${username} ALL=(ALL) NOPASSWD:ALL" | sudo tee "$sudoers_file" >/dev/null || {
                echo -e "${RED}Configure passwordless sudo failed${RESET}"
                return 1
            }
        else
            echo "${username} ALL=(ALL:ALL) ALL" | sudo tee "$sudoers_file" >/dev/null || {
                echo -e "${RED}Configure sudoers entry failed${RESET}"
                return 1
            }
        fi
        sudo chmod 440 "$sudoers_file"
        sudo visudo -cf "$sudoers_file" >/dev/null || {
            echo -e "${RED}sudoers 语法校验失败: $sudoers_file${RESET}"
            return 1
        }
    fi

    # 生成 SSH 密钥
    if [[ "$generate_sshkey" == true ]]; then
        echo -e "${BLUE}生成 SSH 密钥对...${RESET}"
        sudo -u "$username" mkdir -p "$home_dir/.ssh"
        sudo -u "$username" chmod 700 "$home_dir/.ssh"
        if ! sudo -u "$username" ssh-keygen -t rsa -b 4096 -f "$home_dir/.ssh/id_rsa" -N "" -q; then
            echo -e "${RED}SSH key generation failed${RESET}"
            return 1
        fi
        sudo -u "$username" cp "$home_dir/.ssh/id_rsa.pub" "$home_dir/.ssh/authorized_keys"
        sudo -u "$username" chmod 600 "$home_dir/.ssh/authorized_keys"
        echo -e "${GREEN}SSH 私钥路径: $home_dir/.ssh/id_rsa${RESET}"
    fi

    # 输出结果（不打印明文密码，避免进入构建日志）
    echo -e "\n${BOLD}${GREEN}=== 用户创建成功 ===${RESET}"
    echo -e "${YELLOW}用户名:${RESET} $username"
    echo -e "${YELLOW}密码:${RESET} 已设置（明文不输出）"
    echo -e "${YELLOW}家目录:${RESET} $home_dir"
    [[ "$use_sudo" == true ]] && echo -e "${YELLOW}权限:${RESET} sudo 用户"
    [[ "$no_passwd_sudo" == true ]] && echo -e "${YELLOW}Sudo 策略:${RESET} 免密"
    [[ "$generate_sshkey" == true ]] && echo -e "${YELLOW}SSH 密钥:${RESET} 已生成 ($home_dir/.ssh/id_rsa)"
}

merge_and_save_env() {
    local env_dir="/etc/environments"
    local target_file="/etc/environment"
    local temp_file=$(mktemp)
    local filter_regex='^(PATH|PWD|HOME|HOSTNAME|SHLVL|_)='

    echo "=== 开始合并并保存环境变量 ==="

    # 1. 处理 /etc/environment 中已有变量
    if [[ -f "$target_file" ]]; then
        echo "读取 $target_file 中已有变量..."
        while IFS= read -r line; do
            if [[ "$line" =~ ^([^=]+)= ]]; then
                local key="${BASH_REMATCH[1]}"
                echo "$line" >> "$temp_file"
            fi
        done < "$target_file"
    fi

    # 2. 添加当前环境变量
    echo "添加当前环境变量..."
    env | grep -Ev "$filter_regex" | while read -r line; do
        local key="${line%%=*}"
        local value="${line#*=}"
        if grep -q "^${key}=" "$temp_file"; then
            sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$temp_file"
        else
            echo "${key}=\"${value}\"" >> "$temp_file"
        fi
    done

    # 3. 合并 /etc/environments/env-* 中的变量
    if [[ -d "$env_dir" ]]; then
        echo "合并 $env_dir 中的环境变量..."
        for env_file in "$env_dir"/env-*; do
            if [[ -f "$env_file" ]]; then
                while IFS= read -r line; do
                    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
                        local key="${BASH_REMATCH[1]}"
                        local value="${BASH_REMATCH[2]}"
                        if grep -q "^${key}=" "$temp_file"; then
                            sed -i "s|^${key}=.*|${key}=${value}|" "$temp_file"
                        else
                            echo "${key}=${value}" >> "$temp_file"
                        fi
                    fi
                done < "$env_file"
            fi
        done
    fi

    # 4. 删除代理相关变量
    echo "清理代理相关变量..."
    sed -i '/^\(http\|https\|ftp\)_proxy=/Id' "$temp_file"
    sed -i '/^\(HTTP\|HTTPS\|FTP\)_PROXY=/Id' "$temp_file"
    sed -i '/^\(no_proxy\|NO_PROXY\)=/Id' "$temp_file"

    # 5. 更新 /etc/environment
    echo "更新 $target_file 文件..."
    sudo cp "$temp_file" "$target_file"
    sudo chmod 644 "$target_file"
    rm -f "$temp_file"

    # 6. 删除 /etc/environments 目录
    if [[ -d "$env_dir" ]]; then
        echo "删除目录 $env_dir..."
        sudo rm -rf "$env_dir"
    fi

    echo "=== 环境变量合并和保存完成 ==="
    echo "文件路径: $target_file"
    echo "当前内容摘要:"
    sudo cat "$target_file"
}
