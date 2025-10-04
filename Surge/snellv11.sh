#!/bin/bash

# ========== 颜色 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 脚本版本
current_version="5.0"

# 系统路径
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
SYSTEMD_SERVICE_FILE="${SYSTEMD_DIR}/snell.service"

# 全局变量：Snell 版本（例如 v5.0.0b3 / v6.0.0.0）
SNELL_VERSION=""

# ========== 工具检测 ==========
check_root() { [ "$(id -u)" -ne 0 ] && { echo -e "${RED}请以 root 权限运行${RESET}"; exit 1; }; }

check_curl() {
  command -v curl >/dev/null || {
    echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"
    apt update && apt install -y curl || yum install -y curl
  }
}

check_bc() {
  command -v bc >/dev/null || {
    echo -e "${YELLOW}未检测到 bc，正在安装...${RESET}"
    apt update && apt install -y bc || yum install -y bc
  }
}

# 等待 apt 空闲
wait_for_apt() {
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    echo -e "${YELLOW}等待其他 apt 进程完成...${RESET}"
    sleep 1
  done
}

# ========== 获取 Snell 版本 ==========
get_latest_snell_version() {
  local url="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"
  local html v_beta v_stable
  html=$(curl -fsSL --connect-timeout 5 -m 10 "$url") || return 1

  # beta 优先
  v_beta=$(printf '%s' "$html" \
    | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+b[0-9]+' \
    | sed -E 's/^snell-server-v//' \
    | sed -E 's/b([0-9]+)/-beta.\1/' \
    | sort -V | tail -n1 \
    | sed -E 's/-beta\.([0-9]+)/b\1/')

  [ -n "$v_beta" ] && { echo "v${v_beta}"; return 0; }

  # 稳定版
  v_stable=$(printf '%s' "$html" \
    | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' \
    | sed -E 's/^snell-server-v//' \
    | sort -V | tail -n1)

  [ -n "$v_stable" ] && { echo "v${v_stable}"; return 0; }

  return 1
}

# 获取下载链接
get_snell_download_url() {
  local version="$1"
  local arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)  echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-amd64.zip" ;;
    i386|i686)     echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-i386.zip" ;;
    aarch64|arm64) echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-aarch64.zip" ;;
    armv7l|armv7)  echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-armv7l.zip" ;;
    *) echo -e "${RED}不支持的架构: $arch${RESET}" >&2; return 1 ;;
  esac
}

# ========== Surge 配置 ==========
generate_surge_config() {
  local ip=$1 port=$2 psk=$3 country=$4 installed_version=$5
  if [ "$installed_version" = "v5" ]; then
    echo -e "${GREEN}${country} = snell, $ip, $port, psk = $psk, version = 4, reuse = true, tfo = true${RESET}"
    echo -e "${GREEN}${country} = snell, $ip, $port, psk = $psk, version = 5, reuse = true, tfo = true${RESET}"
  else
    echo -e "${GREEN}${country} = snell, $ip, $port, psk = $psk, version = 4, reuse = true, tfo = true${RESET}"
  fi
}

# 检测已安装版本
detect_installed_snell_version() {
  if command -v snell-server >/dev/null; then
    snell-server --v 2>&1 | grep -q "v5" && echo "v5" || echo "v4"
  else
    echo "unknown"
  fi
}

# ========== 安装 Snell ==========
get_user_port() {
  while true; do
    read -rp "请输入端口号 (1-65535，回车随机): " PORT
    if [ -z "$PORT" ]; then
      PORT=$(shuf -i 30000-39999 -n 1)
      echo -e "${GREEN}随机端口: $PORT${RESET}"; break
    elif [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
      echo -e "${GREEN}端口: $PORT${RESET}"; break
    else
      echo -e "${RED}无效输入${RESET}"
    fi
  done
}

install_snell() {
  echo -e "${CYAN}正在安装 Snell...${RESET}"
  SNELL_VERSION=$(get_latest_snell_version) || { echo -e "${RED}获取版本失败${RESET}"; exit 1; }
  SNELL_URL=$(get_snell_download_url "$SNELL_VERSION") || exit 1

  echo -e "${CYAN}下载: ${SNELL_URL}${RESET}"
  wait_for_apt
  apt update && apt install -y wget unzip
  wget -O snell-server.zip "$SNELL_URL" || exit 1
  unzip -o snell-server.zip -d $INSTALL_DIR && rm snell-server.zip
  chmod +x $INSTALL_DIR/snell-server

  get_user_port
  PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

  mkdir -p ${SNELL_CONF_DIR}/users
  cat > $SNELL_CONF_FILE << EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = true
EOF

  cat > $SYSTEMD_SERVICE_FILE << EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=$INSTALL_DIR/snell-server -c $SNELL_CONF_FILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now snell

  echo -e "\n${GREEN}安装完成！${RESET}"
  echo -e "${YELLOW}版本: $SNELL_VERSION${RESET}"
  echo -e "${YELLOW}端口: $PORT${RESET}"
  echo -e "${YELLOW}PSK: $PSK${RESET}"

  IPV4=$(curl -s4 https://api.ipify.org)
  if [ -n "$IPV4" ]; then
    CTRY=$(curl -s http://ipinfo.io/${IPV4}/country)
    generate_surge_config "$IPV4" "$PORT" "$PSK" "$CTRY" "v5"
  fi
}

# ========== 主菜单 ==========
show_menu() {
  clear
  echo -e "${CYAN}========== Snell 管理脚本 v${current_version} ==========${RESET}"
  echo -e "${GREEN}1.${RESET} 安装 Snell"
  echo -e "${GREEN}2.${RESET} 卸载 Snell"
  echo -e "${GREEN}3.${RESET} 查看配置"
  echo -e "${GREEN}4.${RESET} 重启服务"
  echo -e "${GREEN}0.${RESET} 退出"
  read -rp "请选择 [0-4]: " num
}

uninstall_snell() {
  systemctl stop snell
  systemctl disable snell
  rm -f $INSTALL_DIR/snell-server
  rm -rf $SNELL_CONF_DIR
  rm -f $SYSTEMD_SERVICE_FILE
  systemctl daemon-reload
  echo -e "${GREEN}Snell 已卸载${RESET}"
}

view_config() {
  [ -f "$SNELL_CONF_FILE" ] || { echo -e "${RED}未找到配置${RESET}"; return; }
  cat "$SNELL_CONF_FILE"
}

restart_snell() {
  systemctl restart snell && echo -e "${GREEN}已重启 Snell${RESET}"
}

# ========== 入口 ==========
check_root
check_curl
check_bc

while true; do
  show_menu
  case $num in
    1) install_snell ;;
    2) uninstall_snell ;;
    3) view_config ;;
    4) restart_snell ;;
    0) exit 0 ;;
    *) echo -e "${RED}无效选择${RESET}" ;;
  esac
  read -n1 -s -r -p "按任意键返回菜单..."
done
