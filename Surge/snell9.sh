#!/bin/bash

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Snell 安装路径
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
SYSTEMD_SERVICE_FILE="${SYSTEMD_DIR}/snell.service"

# 获取 Snell 最新版本（优先 beta，无兜底）
get_latest_snell_version() {
  local url="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"
  local html v_beta v_stable

  html=$(curl -fsSL --connect-timeout 5 -m 10 "$url") || return 1

  # 先找 beta（5.0.0b1/b2…）
  v_beta=$(printf '%s' "$html" \
    | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+b[0-9]+' \
    | sed -E 's/^snell-server-v//' \
    | sed -E 's/b([0-9]+)/-beta.\1/' \
    | sort -V | tail -n1 \
    | sed -E 's/-beta\.([0-9]+)/b\1/')

  if [ -n "$v_beta" ]; then
    echo "v${v_beta}"
    return 0
  fi

  # 否则取稳定版（支持 x.y.z 或 x.y.z.w）
  v_stable=$(printf '%s' "$html" \
    | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' \
    | sed -E 's/^snell-server-v//' \
    | sort -V | tail -n1)

  [ -n "$v_stable" ] && echo "v${v_stable}" && return 0

  return 1
}

# 获取 Snell 下载 URL
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

# 让用户输入端口（或随机）
get_user_port() {
  while true; do
    read -rp "请输入要使用的端口号 (1-65535，直接回车随机): " PORT
    if [[ -z "$PORT" ]]; then
      PORT=$(shuf -i 30000-39999 -n 1)
      echo -e "${GREEN}已随机选择端口: $PORT${RESET}"
      break
    elif [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
      echo -e "${GREEN}已选择端口: $PORT${RESET}"
      break
    else
      echo -e "${RED}无效端口号，请输入 1 到 65535 之间的数字，或直接回车随机。${RESET}"
    fi
  done
}

# 安装 Snell
install_snell() {
  echo -e "${CYAN}正在获取 Snell 最新版本...${RESET}"
  SNELL_VERSION=$(get_latest_snell_version) || {
    echo -e "${RED}未能获取 Snell 最新版本，安装终止${RESET}"
    exit 1
  }

  SNELL_URL=$(get_snell_download_url "$SNELL_VERSION") || exit 1

  echo -e "${CYAN}将安装 Snell ${SNELL_VERSION}${RESET}"
  echo -e "${YELLOW}下载链接: ${SNELL_URL}${RESET}"

  apt update && apt install -y wget unzip

  wget -O snell-server.zip "$SNELL_URL" || {
    echo -e "${RED}下载失败${RESET}"; exit 1;
  }

  unzip -o snell-server.zip -d ${INSTALL_DIR}
  chmod +x ${INSTALL_DIR}/snell-server
  rm -f snell-server.zip

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
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=${INSTALL_DIR}/snell-server -c ${SNELL_CONF_FILE}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now snell

  echo -e "\n${GREEN}Snell 安装完成！${RESET}"
  echo -e "${YELLOW}端口: ${PORT}${RESET}"
  echo -e "${YELLOW}PSK: ${PSK}${RESET}"
  echo -e "${YELLOW}版本: ${SNELL_VERSION}${RESET}"
}

# 运行安装
install_snell
