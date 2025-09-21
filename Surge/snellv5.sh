#!/bin/bash
set -Eeuo pipefail
trap 'echo -e "\033[0;31m发生错误，退出于行号 $LINENO\033[0m"' ERR

# ===== 颜色 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ===== 脚本版本 =====
current_version="4.6"

# ===== Snell 版本控制（默认 v5.0.0，可输入任意）=====
DEFAULT_SNELL_VERSION="v5.0.0"
SNELL_VERSION=""

# ===== 路径 =====
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
SYSTEMD_SERVICE_FILE="${SYSTEMD_DIR}/snell.service"

# 旧路径（迁移用）
OLD_SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
OLD_SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"

# ===== 基础检查 =====
check_root() {
  if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请以 root 权限运行此脚本${RESET}"
    exit 1
  fi
}

wait_for_apt() {
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    echo -e "${YELLOW}等待其他 apt 进程完成...${RESET}"
    sleep 1
  done
}

check_curl() {
  if ! command -v curl &>/dev/null; then
    echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"
    if command -v apt &>/dev/null; then
      wait_for_apt
      apt update && apt install -y curl
    elif command -v yum &>/dev/null; then
      yum install -y curl
    else
      echo -e "${RED}未支持的包管理器，无法安装 curl。${RESET}"
      exit 1
    fi
  fi
}

check_bc() {
  if ! command -v bc &>/dev/null; then
    echo -e "${YELLOW}未检测到 bc，正在安装...${RESET}"
    if command -v apt &>/dev/null; then
      wait_for_apt
      apt update && apt install -y bc
    elif command -v yum &>/dev/null; then
      yum install -y bc
    else
      echo -e "${RED}未支持的包管理器，无法安装 bc。${RESET}"
      exit 1
    fi
  fi
}

check_jq() {
  if ! command -v jq &>/dev/null; then
    echo -e "${YELLOW}未检测到 jq，正在安装...${RESET}"
    if command -v apt &>/dev/null; then
      wait_for_apt
      apt update && apt install -y jq
    elif command -v yum &>/dev/null; then
      yum install -y jq
    else
      echo -e "${RED}未支持的包管理器，无法安装 jq。${RESET}"
      exit 1
    fi
  fi
}

# ===== 迁移旧配置 =====
check_and_migrate_config() {
  local old_files_exist=false

  if [ -f "$OLD_SNELL_CONF_FILE" ] || [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
    old_files_exist=true
    echo -e "\n${YELLOW}检测到旧版本的 Snell 配置文件${RESET}"
    echo -e "旧配置位置："
    [ -f "$OLD_SNELL_CONF_FILE" ] && echo -e "- 配置文件：${OLD_SNELL_CONF_FILE}"
    [ -f "$OLD_SYSTEMD_SERVICE_FILE" ] && echo -e "- 服务文件：${OLD_SYSTEMD_SERVICE_FILE}"

    if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
      mkdir -p "${SNELL_CONF_DIR}/users"
      chown -R nobody:nogroup "${SNELL_CONF_DIR}" || true
      chmod -R 755 "${SNELL_CONF_DIR}"
    fi
  fi

  if [ "$old_files_exist" = true ]; then
    echo -e "\n${YELLOW}是否要迁移旧的配置文件？[y/N]${RESET}"
    read -r choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
      echo -e "${CYAN}开始迁移配置文件...${RESET}"
      systemctl stop snell 2>/dev/null || true
      if [ -f "$OLD_SNELL_CONF_FILE" ]; then
        cp "$OLD_SNELL_CONF_FILE" "${SNELL_CONF_FILE}"
        chown nobody:nogroup "${SNELL_CONF_FILE}" || true
        chmod 644 "${SNELL_CONF_FILE}"
        echo -e "${GREEN}已迁移配置文件${RESET}"
      fi
      if [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
        sed -e "s|${OLD_SNELL_CONF_FILE}|${SNELL_CONF_FILE}|g" "$OLD_SYSTEMD_SERVICE_FILE" > "$SYSTEMD_SERVICE_FILE"
        chmod 644 "$SYSTEMD_SERVICE_FILE"
        echo -e "${GREEN}已迁移服务文件${RESET}"
      fi
      echo -e "${YELLOW}是否删除旧的配置文件？[y/N]${RESET}"
      read -r del_choice
      if [[ "$del_choice" == "y" || "$del_choice" == "Y" ]]; then
        [ -f "$OLD_SNELL_CONF_FILE" ] && rm -f "$OLD_SNELL_CONF_FILE"
        [ -f "$OLD_SYSTEMD_SERVICE_FILE" ] && rm -f "$OLD_SYSTEMD_SERVICE_FILE"
        echo -e "${GREEN}已删除旧的配置文件${RESET}"
      fi
      systemctl daemon-reload
      systemctl start snell || true
      if systemctl is-active --quiet snell; then
        echo -e "${GREEN}配置迁移完成，服务已成功启动${RESET}"
      else
        echo -e "${RED}警告：服务启动失败，请检查配置文件和权限${RESET}"
        systemctl status snell || true
      fi
    else
      echo -e "${YELLOW}跳过配置迁移${RESET}"
    fi
  fi
}

# ===== 版本/下载处理 =====
detect_cpu_arch() {
  local m
  m=$(uname -m)
  case "$m" in
    x86_64|amd64)   echo "amd64"   ;;
    i386|i686)      echo "i386"    ;;
    aarch64|arm64)  echo "aarch64" ;;
    armv7l|armv7)   echo "armv7l"  ;;
    *) echo -e "${RED}不支持的架构: $m${RESET}" >&2; return 1 ;;
  esac
}

build_snell_url() {
  local version="$1" arch="$2"
  echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-${arch}.zip"
}

prompt_snell_version() {
  local arch url
  arch=$(detect_cpu_arch) || exit 1
  while true; do
    read -rp "请输入 Snell 版本号（直接回车默认 ${DEFAULT_SNELL_VERSION}）： " SNELL_VERSION
    if [[ -z "$SNELL_VERSION" ]]; then
      SNELL_VERSION="$DEFAULT_SNELL_VERSION"
    fi
    [[ "$SNELL_VERSION" =~ ^v ]] || SNELL_VERSION="v${SNELL_VERSION}"

    url=$(build_snell_url "$SNELL_VERSION" "$arch")

    # ↓↓↓ 状态信息改走 stderr ↓↓↓
    echo -e "${CYAN}校验下载地址：${url}${RESET}" >&2
    if curl -sfI "$url" >/dev/null 2>&1; then
      echo -e "${GREEN}版本有效，准备下载。${RESET}" >&2
      echo "$url"   # ← 只把 URL 打到 stdout
      return 0
    fi

    echo -e "${RED}无法下载该版本：${SNELL_VERSION}${RESET}" >&2
    read -rp "是否改为安装默认版本 ${DEFAULT_SNELL_VERSION}？[Y/n]: " yn
    yn=${yn:-Y}
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      SNELL_VERSION="$DEFAULT_SNELL_VERSION"
      url=$(build_snell_url "$SNELL_VERSION" "$arch")
      echo -e "${CYAN}校验下载地址：${url}${RESET}" >&2
      if curl -sfI "$url" >/dev/null 2>&1; then
        echo -e "${GREEN}默认版本可用，准备下载。${RESET}" >&2
        echo "$url"
        return 0
      else
        echo -e "${RED}默认版本也不可用，请稍后重试。${RESET}" >&2
        exit 1
      fi
    fi
    echo -e "${YELLOW}请重新输入一个可用的版本号。${RESET}" >&2
  done
}

# ===== 功能工具 =====
check_snell_installed() {
  if command -v snell-server &>/dev/null; then return 0; else return 1; fi
}

detect_installed_snell_version() {
  if command -v snell-server &>/dev/null; then
    local version_output
    version_output=$(snell-server --v 2>&1 || snell-server -v 2>&1 || snell-server --version 2>&1 || true)
    if echo "$version_output" | grep -q "v5"; then
      echo "v5"
    elif echo "$version_output" | grep -q "v4"; then
      echo "v4"
    else
      echo "v5"  # 保守地当作 v5
    fi
  else
    echo "unknown"
  fi
}

backup_snell_config() {
  local backup_dir="/etc/snell/backup_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$backup_dir"
  cp -a /etc/snell/users/*.conf "$backup_dir"/ 2>/dev/null || true
  echo "$backup_dir"
}

restore_snell_config() {
  local backup_dir="$1"
  if [ -d "$backup_dir" ]; then
    cp -a "$backup_dir"/*.conf /etc/snell/users/ 2>/dev/null || true
    echo -e "${GREEN}配置已从备份恢复。${RESET}"
  else
    echo -e "${RED}未找到备份目录，无法恢复配置。${RESET}"
  fi
}

get_user_port() {
  while true; do
    read -rp "请输入要使用的端口号 (1-65535，直接回车随机): " PORT
    if [[ -z "$PORT" ]]; then
      PORT=$(shuf -i 49152-65535 -n 1)
      echo -e "${GREEN}已随机选择端口: $PORT${RESET}"
      break
    elif [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
      echo -e "${GREEN}已选择端口: $PORT${RESET}"
      break
    else
      echo -e "${RED}无效端口号，请输入 1-65535 或回车随机。${RESET}"
    fi
  done
}

open_port() {
  local PORT=$1
  if command -v ufw &>/dev/null; then
    echo -e "${CYAN}在 UFW 中开放端口 $PORT${RESET}"
    ufw allow "$PORT"/tcp || true
    ufw allow "$PORT"/udp || true
  fi
  if command -v iptables &>/dev/null; then
    echo -e "${CYAN}在 iptables 中开放端口 $PORT${RESET}"
    iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT || true
    iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT || true
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 || true
  fi
}

generate_surge_config() {
  local ip_addr=$1
  local port=$2
  local psk=$3
  local country=$4
  echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
  echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true${RESET}"
}

get_snell_port() {
  if [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ]; then
    grep -E '^listen' "${SNELL_CONF_DIR}/users/snell-main.conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p'
  fi
}

# ===== 安装 =====
install_snell() {
  echo -e "${CYAN}正在安装 Snell${RESET}"
  wait_for_apt
  if command -v apt &>/dev/null; then
    apt update && apt install -y wget unzip
  elif command -v yum &>/dev/null; then
    yum install -y wget unzip
  fi

  local SNELL_URL
  SNELL_URL=$(prompt_snell_version) || exit 1

  echo -e "${CYAN}正在下载 Snell ${SNELL_VERSION}...${RESET}"
  echo -e "${YELLOW}下载链接: ${SNELL_URL}${RESET}"
  wget -q "${SNELL_URL}" -O snell-server.zip
  unzip -o snell-server.zip -d ${INSTALL_DIR}
  rm -f snell-server.zip
  chmod +x ${INSTALL_DIR}/snell-server

  get_user_port
  PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

  mkdir -p ${SNELL_CONF_DIR}/users
  cat > ${SNELL_CONF_FILE} << EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = true
EOF

  cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service (Main)
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=${INSTALL_DIR}/snell-server -c ${SNELL_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable snell
  systemctl start snell

  open_port "$PORT"

  echo -e "\n${GREEN}安装完成！以下是您的配置信息：${RESET}"
  echo -e "${CYAN}--------------------------------${RESET}"
  echo -e "${YELLOW}监听端口: ${PORT}${RESET}"
  echo -e "${YELLOW}PSK 密钥: ${PSK}${RESET}"
  echo -e "${YELLOW}IPv6: true${RESET}"
  echo -e "${CYAN}--------------------------------${RESET}"

  echo -e "\n${GREEN}服务器地址信息：${RESET}"
  IPV4_ADDR=$(curl -s4 https://api.ipify.org || true)
  if [ -n "${IPV4_ADDR:-}" ]; then
    IP_COUNTRY_IPV4=$(curl -s http://ipinfo.io/${IPV4_ADDR}/country || true)
    echo -e "${GREEN}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
  fi
  IPV6_ADDR=$(curl -s6 https://api64.ipify.org || true)
  if [ -n "${IPV6_ADDR:-}" ]; then
    IP_COUNTRY_IPV6=$(curl -s https://ipapi.co/${IPV6_ADDR}/country/ || true)
    echo -e "${GREEN}IPv6 地址: ${RESET}${IPV6_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV6}"
  fi

  echo -e "\n${GREEN}Surge 配置格式：${RESET}"
  if [ -n "${IPV4_ADDR:-}" ]; then
    generate_surge_config "$IPV4_ADDR" "$PORT" "$PSK" "$IP_COUNTRY_IPV4"
  fi
  if [ -n "${IPV6_ADDR:-}" ]; then
    generate_surge_config "$IPV6_ADDR" "$PORT" "$PSK" "$IP_COUNTRY_IPV6"
  fi

  # 管理脚本（保留）
  echo -e "${CYAN}正在安装管理脚本...${RESET}"
  mkdir -p /usr/local/bin
  cat > /usr/local/bin/snell << 'EOFSCRIPT'
#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
if [ "$(id -u)" != "0" ]; then echo -e "${RED}请以 root 权限运行此脚本${RESET}"; exit 1; fi
echo -e "${CYAN}正在获取最新版本的管理脚本...${RESET}"
TMP_SCRIPT=$(mktemp)
if curl -sL https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/snell.sh -o "$TMP_SCRIPT"; then
  bash "$TMP_SCRIPT"
  rm -f "$TMP_SCRIPT"
else
  echo -e "${RED}下载脚本失败，请检查网络连接。${RESET}"
  rm -f "$TMP_SCRIPT"
  exit 1
fi
EOFSCRIPT
  chmod +x /usr/local/bin/snell || true
  echo -e "\n${GREEN}管理脚本安装成功！${RESET}"
  echo -e "${YELLOW}您可以在终端输入 'snell' 进入管理菜单（需 root）。${RESET}\n"
}

# ===== 更新（仅替换二进制，不动配置）=====
update_snell_binary_internal() {
  local url="$1"
  echo -e "${CYAN}正在备份当前配置...${RESET}"
  local backup_dir
  backup_dir=$(backup_snell_config)
  echo -e "${GREEN}配置已备份到: $backup_dir${RESET}"

  echo -e "${CYAN}下载并替换二进制...${RESET}"
  wget -q "${url}" -O snell-server.zip
  unzip -o snell-server.zip -d ${INSTALL_DIR}
  rm -f snell-server.zip
  chmod +x ${INSTALL_DIR}/snell-server

  systemctl restart snell || { echo -e "${RED}主服务重启失败，尝试恢复配置...${RESET}"; restore_snell_config "$backup_dir"; systemctl restart snell || true; }

  if [ -d "${SNELL_CONF_DIR}/users" ]; then
    for user_conf in "${SNELL_CONF_DIR}/users"/*; do
      if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
        local port
        port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        [ -n "${port:-}" ] && systemctl restart "snell-${port}" 2>/dev/null || true
      fi
    done
  fi

  echo -e "${GREEN}✅ 已更新到: ${SNELL_VERSION}${RESET}"
  echo -e "${YELLOW}配置备份目录: $backup_dir${RESET}"
}

update_snell_binary() {
  local url
  url=$(prompt_snell_version) || { echo -e "${RED}版本校验失败${RESET}"; return 1; }
  update_snell_binary_internal "$url"
}

check_snell_update() {
  echo -e "\n${CYAN}=============== Snell 更新 ===============${RESET}"
  local url
  url=$(prompt_snell_version) || { echo -e "${RED}版本校验失败${RESET}"; return 1; }
  echo -e "${YELLOW}将更新到: ${SNELL_VERSION}${RESET}"
  read -rp "确认更新？[Y/n]: " yn
  yn=${yn:-Y}
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    update_snell_binary_internal "$url"
  else
    echo -e "${YELLOW}已取消更新${RESET}"
  fi
}

# ===== 卸载 / 重启 =====
uninstall_snell() {
  echo -e "${CYAN}正在卸载 Snell${RESET}"
  systemctl stop snell || true
  systemctl disable snell || true

  if [ -d "${SNELL_CONF_DIR}/users" ]; then
    for user_conf in "${SNELL_CONF_DIR}/users"/*; do
      if [ -f "$user_conf" ]; then
        local port
        port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        if [ -n "$port" ]; then
          echo -e "${YELLOW}停止多用户服务 (端口: $port)${RESET}"
          systemctl stop "snell-${port}" 2>/dev/null || true
          systemctl disable "snell-${port}" 2>/dev/null || true
          rm -f "${SYSTEMD_DIR}/snell-${port}.service"
        fi
      fi
    done
  fi

  rm -f /etc/systemd/system/snell.service
  rm -f /usr/local/bin/snell-server
  rm -rf ${SNELL_CONF_DIR}
  rm -f /usr/local/bin/snell
  systemctl daemon-reload
  echo -e "${GREEN}Snell 及其所有多用户配置已成功卸载${RESET}"
}

restart_snell() {
  echo -e "${YELLOW}正在重启所有 Snell 服务...${RESET}"
  systemctl restart snell && echo -e "${GREEN}主服务已重启${RESET}" || echo -e "${RED}主服务重启失败${RESET}"
  if [ -d "${SNELL_CONF_DIR}/users" ]; then
    for user_conf in "${SNELL_CONF_DIR}/users"/*; do
      if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
        local port
        port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        if [ -n "$port" ]; then
          echo -e "${YELLOW}重启用户服务 (端口: $port)${RESET}"
          systemctl restart "snell-${port}" 2>/dev/null && echo -e "${GREEN}已重启${RESET}" || echo -e "${RED}重启失败${RESET}"
        fi
      fi
    done
  fi
}

# ===== 状态与查看配置 =====
check_and_show_status() {
  echo -e "\n${CYAN}=============== 服务状态检查 ===============${RESET}"

  if command -v snell-server &>/dev/null; then
    local user_count=0 running_count=0 total_snell_memory=0 total_snell_cpu=0

    if systemctl is-active snell &>/dev/null; then
      user_count=$((user_count + 1)); running_count=$((running_count + 1))
      local main_pid
      main_pid=$(systemctl show -p MainPID snell | cut -d'=' -f2)
      if [ -n "${main_pid:-}" ] && [ "$main_pid" != "0" ]; then
        local mem cpu
        mem=$(ps -o rss= -p $main_pid 2>/dev/null || echo 0)
        cpu=$(ps -o %cpu= -p $main_pid 2>/dev/null || echo 0)
        total_snell_memory=$((total_snell_memory + ${mem:-0}))
        total_snell_cpu=$(echo "${total_snell_cpu:-0} + ${cpu:-0}" | bc -l)
      fi
    else
      user_count=$((user_count + 1))
    fi

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
      for user_conf in "${SNELL_CONF_DIR}/users"/*; do
        if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
          local port
          port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
          if [ -n "$port" ]; then
            user_count=$((user_count + 1))
            if systemctl is-active --quiet "snell-${port}"; then
              running_count=$((running_count + 1))
              local user_pid mem cpu
              user_pid=$(systemctl show -p MainPID "snell-${port}" | cut -d'=' -f2)
              if [ -n "${user_pid:-}" ] && [ "$user_pid" != "0" ]; then
                mem=$(ps -o rss= -p $user_pid 2>/dev/null || echo 0)
                cpu=$(ps -o %cpu= -p $user_pid 2>/dev/null || echo 0)
                total_snell_memory=$((total_snell_memory + ${mem:-0}))
                total_snell_cpu=$(echo "${total_snell_cpu:-0} + ${cpu:-0}" | bc -l)
              fi
            fi
          fi
        fi
      done
    fi

    local total_snell_memory_mb
    total_snell_memory_mb=$(echo "scale=2; ${total_snell_memory}/1024" | bc)
    printf "${GREEN}Snell 已安装${RESET}  ${YELLOW}CPU：%.2f%%${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：%s/%s${RESET}\n" "${total_snell_cpu:-0}" "${total_snell_memory_mb:-0}" "$running_count" "$user_count"
  else
    echo -e "${YELLOW}Snell 未安装${RESET}"
  fi

  if [ -f "/usr/local/bin/shadow-tls" ]; then
    local stls_total=0 stls_running=0 total_stls_memory=0 total_stls_cpu=0
    declare -A processed_ports
    local snell_services
    snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u || true)
    if [ -n "${snell_services:-}" ]; then
      while IFS= read -r service_file; do
        local port
        port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
        if [ -z "${processed_ports[$port]:-}" ]; then
          processed_ports[$port]=1
          stls_total=$((stls_total + 1))
          if systemctl is-active "shadowtls-snell-${port}" &>/dev/null; then
            stls_running=$((stls_running + 1))
            local stls_pid mem cpu
            stls_pid=$(systemctl show -p MainPID "shadowtls-snell-${port}" | cut -d'=' -f2)
            if [ -n "${stls_pid:-}" ] && [ "$stls_pid" != "0" ]; then
              mem=$(ps -o rss= -p $stls_pid 2>/dev/null || echo 0)
              cpu=$(ps -o %cpu= -p $stls_pid 2>/dev/null || echo 0)
              total_stls_memory=$((total_stls_memory + ${mem:-0}))
              total_stls_cpu=$(echo "${total_stls_cpu:-0} + ${cpu:-0}" | bc -l)
            fi
          fi
        fi
      done <<< "$snell_services"
    fi
    if [ $stls_total -gt 0 ]; then
      local total_stls_memory_mb
      total_stls_memory_mb=$(echo "scale=2; $total_stls_memory/1024" | bc)
      printf "${GREEN}ShadowTLS 已安装${RESET}  ${YELLOW}CPU：%.2f%%${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：%s/%s${RESET}\n" "${total_stls_cpu:-0}" "${total_stls_memory_mb:-0}" "$stls_running" "$stls_total"
    else
      echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
    fi
  else
    echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
  fi

  echo -e "${CYAN}============================================${RESET}\n"
}

view_snell_config() {
  echo -e "${GREEN}Snell 配置信息:${RESET}"
  echo -e "${CYAN}================================${RESET}"

  local installed_version
  installed_version=$(detect_installed_snell_version)
  if [ "$installed_version" != "unknown" ]; then
    echo -e "${YELLOW}当前安装版本: Snell ${installed_version}${RESET}"
  fi

  IPV4_ADDR=$(curl -s4 https://api.ipify.org || true)
  if [ -n "${IPV4_ADDR:-}" ]; then
    IP_COUNTRY_IPV4=$(curl -s http://ipinfo.io/${IPV4_ADDR}/country || true)
    echo -e "${GREEN}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
  fi
  IPV6_ADDR=$(curl -s6 https://api64.ipify.org || true)
  if [ -n "${IPV6_ADDR:-}" ]; then
    IP_COUNTRY_IPV6=$(curl -s https://ipapi.co/${IPV6_ADDR}/country/ || true)
    echo -e "${GREEN}IPv6 地址: ${RESET}${IPV6_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV6}"
  fi
  if [ -z "${IPV4_ADDR:-}" ] && [ -z "${IPV6_ADDR:-}" ]; then
    echo -e "${RED}无法获取到公网 IP 地址，请检查网络连接。${RESET}"
    return
  fi

  echo -e "\n${YELLOW}=== 用户配置列表 ===${RESET}"
  local main_conf="${SNELL_CONF_DIR}/users/snell-main.conf"
  if [ -f "$main_conf" ]; then
    echo -e "\n${GREEN}主用户配置：${RESET}"
    local main_port main_psk main_ipv6
    main_port=$(grep -E '^listen' "$main_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
    main_psk=$(grep -E '^psk' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
    main_ipv6=$(grep -E '^ipv6' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
    echo -e "${YELLOW}端口: ${main_port}${RESET}"
    echo -e "${YELLOW}PSK: ${main_psk}${RESET}"
    echo -e "${YELLOW}IPv6: ${main_ipv6}${RESET}"
    echo -e "\n${GREEN}Surge 配置格式：${RESET}"
    [ -n "${IPV4_ADDR:-}" ] && generate_surge_config "$IPV4_ADDR" "$main_port" "$main_psk" "$IP_COUNTRY_IPV4"
    [ -n "${IPV6_ADDR:-}" ] && generate_surge_config "$IPV6_ADDR" "$main_port" "$main_psk" "$IP_COUNTRY_IPV6"
  fi

  if [ -d "${SNELL_CONF_DIR}/users" ]; then
    for user_conf in "${SNELL_CONF_DIR}/users"/*; do
      if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
        local user_port user_psk user_ipv6
        user_port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        user_psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        user_ipv6=$(grep -E '^ipv6' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        echo -e "\n${GREEN}用户配置 (端口: ${user_port}):${RESET}"
        echo -e "${YELLOW}PSK: ${user_psk}${RESET}"
        echo -e "${YELLOW}IPv6: ${user_ipv6}${RESET}"
        echo -e "\n${GREEN}Surge 配置格式：${RESET}"
        [ -n "${IPV4_ADDR:-}" ] && generate_surge_config "$IPV4_ADDR" "$user_port" "$user_psk" "$IP_COUNTRY_IPV4"
        [ -n "${IPV6_ADDR:-}" ] && generate_surge_config "$IPV6_ADDR" "$user_port" "$user_psk" "$IP_COUNTRY_IPV6"
      fi
    done
  fi

  local snell_version
  snell_version=$(detect_installed_snell_version)
  local snell_services
  snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u || true)
  if [ -n "${snell_services:-}" ]; then
    echo -e "\n${YELLOW}=== ShadowTLS 组合配置 ===${RESET}"
    declare -A processed_ports
    while IFS= read -r service_file; do
      local exec_line stls_port stls_password stls_domain snell_port psk=""
      exec_line=$(grep "ExecStart=" "$service_file")
      stls_port=$(echo "$exec_line" | grep -oP '(?<=--listen ::0:)\d+')
      stls_password=$(echo "$exec_line" | grep -oP '(?<=--password )[^ ]+')
      stls_domain=$(echo "$exec_line" | grep -oP '(?<=--tls )[^ ]+')
      snell_port=$(echo "$exec_line" | grep -oP '(?<=--server 127.0.0.1:)\d+')
      if [ -f "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" ]; then
        psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" | awk -F'=' '{print $2}' | tr -d ' ')
      elif [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ] && [ "$snell_port" = "$(get_snell_port)" ]; then
        psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-main.conf" | awk -F'=' '{print $2}' | tr -d ' ')
      fi
      if [ -z "$snell_port" ] || [ -z "$psk" ] || [ -n "${processed_ports[$snell_port]:-}" ]; then
        continue
      fi
      processed_ports[$snell_port]=1
      if [ "$snell_port" = "$(get_snell_port)" ]; then
        echo -e "\n${GREEN}主用户 ShadowTLS 配置：${RESET}"
      else
        echo -e "\n${GREEN}用户 ShadowTLS 配置 (端口: ${snell_port})：${RESET}"
      fi
      echo -e "  - Snell 端口：${snell_port}"
      echo -e "  - PSK：${psk}"
      echo -e "  - ShadowTLS 监听端口：${stls_port}"
      echo -e "  - ShadowTLS 密码：${stls_password}"
      echo -e "  - ShadowTLS SNI：${stls_domain}"
      echo -e "  - 版本：3"
      echo -e "\n${GREEN}Surge 配置格式：${RESET}"
      if [ -n "${IPV4_ADDR:-}" ]; then
        echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
        echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
      fi
      if [ -n "${IPV6_ADDR:-}" ]; then
        echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
        echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
      fi
    done <<< "$snell_services"
  fi

  echo -e "\n${YELLOW}注意：${RESET}"
  echo -e "1. Snell 仅支持 Surge 客户端"
  echo -e "2. 请将配置中的服务器地址替换为实际可用的地址"
  read -p "按任意键返回主菜单..."
}

# ===== 其他 =====
check_installation() {
  local service=$1
  if systemctl list-unit-files | grep -q "^$service.service"; then
    echo -e "${GREEN}已安装${RESET}"
  else
    echo -e "${RED}未安装${RESET}"
  fi
}

get_shadowtls_config() {
  local main_port service_name service_file exec_line tls_domain password listen_part listen_port
  main_port=$(get_snell_port)
  [ -n "${main_port:-}" ] || return 1
  service_name="shadowtls-snell-${main_port}"
  systemctl is-active --quiet "$service_name" || return 1
  service_file="/etc/systemd/system/${service_name}.service"
  [ -f "$service_file" ] || return 1
  exec_line=$(grep "ExecStart=" "$service_file" || true)
  [ -n "$exec_line" ] || return 1
  tls_domain=$(echo "$exec_line" | grep -o -- "--tls [^ ]*" | cut -d' ' -f2)
  password=$(echo "$exec_line" | grep -o -- "--password [^ ]*" | cut -d' ' -f2)
  listen_part=$(echo "$exec_line" | grep -o -- "--listen [^ ]*" | cut -d' ' -f2)
  listen_port=$(echo "$listen_part" | grep -o '[0-9]*$')
  [ -n "$tls_domain" ] && [ -n "$password" ] && [ -n "$listen_port" ] || return 1
  echo "${password}|${tls_domain}|${listen_port}"
  return 0
}

# ===== 初始检查 =====
initial_check() {
  check_root
  check_curl
  check_bc
  check_jq
  check_and_migrate_config
  check_and_show_status
}
initial_check

# ===== 扩展功能（外部脚本）=====
setup_multi_user() {
  echo -e "${CYAN}正在执行多用户管理脚本...${RESET}"
  bash <(curl -sL https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/multi-user.sh)
  echo -e "${GREEN}多用户管理操作完成${RESET}"
  sleep 1
}

setup_bbr() {
  echo -e "${CYAN}正在获取并执行 BBR 管理脚本...${RESET}"
  bash <(curl -sL https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/bbr.sh)
  echo -e "${GREEN}BBR 管理操作完成${RESET}"
  sleep 1
}

setup_shadowtls() {
  echo -e "${CYAN}正在执行 ShadowTLS 管理脚本...${RESET}"
  bash <(curl -sL https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/shadowtls.sh)
  echo -e "${GREEN}ShadowTLS 管理操作完成${RESET}"
  sleep 1
}

# ===== 脚本自更新（保留原逻辑）=====
auto_update_script() {
  echo -e "${CYAN}正在检查脚本更新...${RESET}"
  TMP_SCRIPT=$(mktemp)
  if curl -sL https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/snell.sh -o "$TMP_SCRIPT"; then
    new_version=$(grep "current_version=" "$TMP_SCRIPT" | cut -d'"' -f2 || true)
    if [ -n "${new_version:-}" ] && [ "$new_version" != "$current_version" ]; then
      echo -e "${GREEN}发现新版本：${new_version}${RESET}"
      echo -e "${YELLOW}当前版本：${current_version}${RESET}"
      cp "$0" "${0}.backup"
      mv "$TMP_SCRIPT" "$0"
      chmod +x "$0"
      echo -e "${GREEN}脚本已更新到最新版本${RESET}"
      echo -e "${YELLOW}已备份原脚本到：${0}.backup${RESET}"
      echo -e "${CYAN}请重新运行脚本以使用新版本${RESET}"
      exit 0
    else
      echo -e "${GREEN}当前已是最新版本 (${current_version})${RESET}"
      rm -f "$TMP_SCRIPT"
    fi
  else
    echo -e "${RED}检查更新失败，请检查网络连接${RESET}"
    rm -f "$TMP_SCRIPT"
  fi
}

update_script() {
  echo -e "${CYAN}正在检查脚本更新...${RESET}"
  TMP_SCRIPT=$(mktemp)
  if curl -sL https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/snell.sh -o "$TMP_SCRIPT"; then
    new_version=$(grep "current_version=" "$TMP_SCRIPT" | cut -d'"' -f2 || true)
    if [ -z "${new_version:-}" ]; then
      echo -e "${RED}无法获取新版本信息${RESET}"
      rm -f "$TMP_SCRIPT"
      return 1
    fi
    echo -e "${YELLOW}当前版本：${current_version}${RESET}"
    echo -e "${YELLOW}最新版本：${new_version}${RESET}"
    if [ "$new_version" != "$current_version" ]; then
      echo -e "${CYAN}是否更新到新版本？[y/N]${RESET}"
      read -r choice
      if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        SCRIPT_PATH=$(readlink -f "$0")
        cp "$SCRIPT_PATH" "${SCRIPT_PATH}.backup"
        mv "$TMP_SCRIPT" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        echo -e "${GREEN}脚本已更新到最新版本${RESET}"
        echo -e "${YELLOW}已备份原脚本到：${SCRIPT_PATH}.backup${RESET}"
        echo -e "${CYAN}请重新运行脚本以使用新版本${RESET}"
        exit 0
      else
        echo -e "${YELLOW}已取消更新${RESET}"
        rm -f "$TMP_SCRIPT"
      fi
    else
      echo -e "${GREEN}当前已是最新版本${RESET}"
      rm -f "$TMP_SCRIPT"
    fi
  else
    echo -e "${RED}下载新版本失败，请检查网络连接${RESET}"
    rm -f "$TMP_SCRIPT"
  fi
}

# ===== 多用户辅助 =====
get_all_snell_users() {
  [ -d "${SNELL_CONF_DIR}/users" ] || return 1
  local main_port="" main_psk=""
  if [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ]; then
    main_port=$(grep -E '^listen' "${SNELL_CONF_DIR}/users/snell-main.conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
    main_psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-main.conf" | awk -F'=' '{print $2}' | tr -d ' ')
    if [ -n "$main_port" ] && [ -n "$main_psk" ]; then
      echo "${main_port}|${main_psk}"
    fi
  fi
  for user_conf in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
    if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
      local port psk
      port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
      psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
      if [ -n "$port" ] && [ -n "$psk" ]; then
        echo "${port}|${psk}"
      fi
    fi
  done
}

# ===== 主菜单 =====
show_menu() {
  clear
  echo -e "${CYAN}============================================${RESET}"
  echo -e "${CYAN}          Snell 管理脚本 v${current_version}${RESET}"
  echo -e "${CYAN}============================================${RESET}"
  check_and_show_status
  echo -e "${YELLOW}=== 基础功能 ===${RESET}"
  echo -e "${GREEN}1.${RESET} 安装 Snell"
  echo -e "${GREEN}2.${RESET} 卸载 Snell"
  echo -e "${GREEN}3.${RESET} 查看配置"
  echo -e "${GREEN}4.${RESET} 重启服务"
  echo -e "\n${YELLOW}=== 增强功能 ===${RESET}"
  echo -e "${GREEN}5.${RESET} ShadowTLS 管理"
  echo -e "${GREEN}6.${RESET} BBR 管理"
  echo -e "${GREEN}7.${RESET} 多用户管理"
  echo -e "\n${YELLOW}=== 系统功能 ===${RESET}"
  echo -e "${GREEN}8.${RESET} 更新Snell（输入或默认版本）"
  echo -e "${GREEN}9.${RESET} 更新脚本"
  echo -e "${GREEN}10.${RESET} 查看服务状态"
  echo -e "${GREEN}0.${RESET} 退出脚本"
  echo -e "${CYAN}============================================${RESET}"
  read -rp "请输入选项 [0-10]: " num
}

# ===== 入口循环 =====
while true; do
  show_menu
  case "$num" in
    1) install_snell ;;
    2) uninstall_snell ;;
    3) view_snell_config ;;
    4) restart_snell ;;
    5) setup_shadowtls ;;
    6) setup_bbr ;;
    7) setup_multi_user ;;
    8) check_snell_update ;;
    9) update_script ;;
    10) check_and_show_status; read -p "按任意键继续..." ;;
    0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
    *) echo -e "${RED}请输入正确的选项 [0-10]${RESET}" ;;
  esac
  echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
  read -n 1 -s -r
done
