#!/bin/bash

# 定义颜色代码

RED=’\033[0;31m’
GREEN=’\033[0;32m’
YELLOW=’\033[0;33m’
CYAN=’\033[0;36m’
RESET=’\033[0m’

# 当前版本号

current_version=“4.9”

# 全局变量：固定版本号（修改此处即可更新版本）

SNELL_VERSION=“v5.0.0”

# 获取 Snell 下载 URL

get_snell_download_url() {
local arch=$(uname -m)

```
# v5 版本自动拼接下载链接
case ${arch} in
    "x86_64"|"amd64")
        echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-amd64.zip"
        ;;
    "i386"|"i686")
        echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-i386.zip"
        ;;
    "aarch64"|"arm64")
        echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-aarch64.zip"
        ;;
    "armv7l"|"armv7")
        echo "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-armv7l.zip"
        ;;
    *)
        echo -e "${RED}不支持的架构: ${arch}${RESET}"
        exit 1
        ;;
esac
```

}

# 生成 Surge 配置格式（仅 v5）

generate_surge_config() {
local ip_addr=$1
local port=$2
local psk=$3
local country=$4

```
# 仅输出 v5 配置
echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true${RESET}"
```

}

# 检查 bc 是否安装

check_bc() {
if ! command -v bc &> /dev/null; then
echo -e “${YELLOW}未检测到 bc，正在安装…${RESET}”
if [ -x “$(command -v apt)” ]; then
wait_for_apt
apt update && apt install -y bc
elif [ -x “$(command -v yum)” ]; then
yum install -y bc
else
echo -e “${RED}未支持的包管理器，无法安装 bc。请手动安装 bc。${RESET}”
exit 1
fi
fi
}

# 检查 curl 是否安装

check_curl() {
if ! command -v curl &> /dev/null; then
echo -e “${YELLOW}未检测到 curl，正在安装…${RESET}”
if [ -x “$(command -v apt)” ]; then
wait_for_apt
apt update && apt install -y curl
elif [ -x “$(command -v yum)” ]; then
yum install -y curl
else
echo -e “${RED}未支持的包管理器，无法安装 curl。请手动安装 curl。${RESET}”
exit 1
fi
fi
}

# 定义系统路径

INSTALL_DIR=”/usr/local/bin”
SYSTEMD_DIR=”/etc/systemd/system”
SNELL_CONF_DIR=”/etc/snell”
SNELL_CONF_FILE=”${SNELL_CONF_DIR}/users/snell-main.conf”
SYSTEMD_SERVICE_FILE=”${SYSTEMD_DIR}/snell.service”

# 等待其他 apt 进程完成

wait_for_apt() {
while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
echo -e “${YELLOW}等待其他 apt 进程完成…${RESET}”
sleep 1
done
}

# 检查是否以 root 权限运行

check_root() {
if [ “$(id -u)” != “0” ]; then
echo -e “${RED}请以 root 权限运行此脚本${RESET}”
exit 1
fi
}

# 用户输入端口号，范围 1-65535；直接回车则随机生成

get_user_port() {
while true; do
read -rp “请输入要使用的端口号 (1-65535，直接回车随机): “ PORT
if [[ -z “$PORT” ]]; then
PORT=$(shuf -i 30000-39999 -n 1)
echo -e “${GREEN}已随机选择端口: $PORT${RESET}”
break
elif [[ “$PORT” =~ ^[0-9]+$ ]] && [ “$PORT” -ge 1 ] && [ “$PORT” -le 65535 ]; then
echo -e “${GREEN}已选择端口: $PORT${RESET}”
break
else
echo -e “${RED}无效端口号，请输入 1 到 65535 之间的数字，或直接回车随机。${RESET}”
fi
done
}

# 开放端口 (ufw 和 iptables)

open_port() {
local PORT=$1
if command -v ufw &> /dev/null; then
echo -e “${CYAN}在 UFW 中开放端口 $PORT${RESET}”
ufw allow “$PORT”/tcp
ufw allow “$PORT”/udp
fi

```
if command -v iptables &> /dev/null; then
    echo -e "${CYAN}在 iptables 中开放端口 $PORT${RESET}"
    iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
    iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT

    if [ ! -d "/etc/iptables" ]; then
        mkdir -p /etc/iptables
    fi
    iptables-save > /etc/iptables/rules.v4 || true
fi
```

}

# 安装 Snell v5

install_snell() {
echo -e “${CYAN}正在安装 Snell ${SNELL_VERSION}${RESET}”

```
wait_for_apt
apt update && apt install -y wget unzip

ARCH=$(uname -m)
SNELL_URL=$(get_snell_download_url)

echo -e "${CYAN}正在下载 Snell ${SNELL_VERSION}...${RESET}"
echo -e "${YELLOW}下载链接: ${SNELL_URL}${RESET}"

wget ${SNELL_URL} -O snell-server.zip
if [ $? -ne 0 ]; then
    echo -e "${RED}下载 Snell ${SNELL_VERSION} 失败。${RESET}"
    exit 1
fi

unzip -o snell-server.zip -d ${INSTALL_DIR}
if [ $? -ne 0 ]; then
    echo -e "${RED}解压缩 Snell 失败。${RESET}"
    exit 1
fi

rm snell-server.zip
chmod +x ${INSTALL_DIR}/snell-server

get_user_port
PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

mkdir -p ${SNELL_CONF_DIR}/users

cat > ${SNELL_CONF_FILE} << EOF
```

[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = true
EOF

```
cat > ${SYSTEMD_SERVICE_FILE} << EOF
```

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

```
systemctl daemon-reload
if [ $? -ne 0 ]; then
    echo -e "${RED}重载 Systemd 配置失败。${RESET}"
    exit 1
fi

systemctl enable snell
if [ $? -ne 0 ]; then
    echo -e "${RED}开机自启动 Snell 失败。${RESET}"
    exit 1
fi

systemctl start snell
if [ $? -ne 0 ]; then
    echo -e "${RED}启动 Snell 服务失败。${RESET}"
    exit 1
fi

open_port "$PORT"

echo -e "\n${GREEN}安装完成！以下是您的配置信息：${RESET}"
echo -e "${CYAN}--------------------------------${RESET}"
echo -e "${YELLOW}监听端口: ${PORT}${RESET}"
echo -e "${YELLOW}PSK 密钥: ${PSK}${RESET}"
echo -e "${YELLOW}版本: ${SNELL_VERSION}${RESET}"
echo -e "${YELLOW}IPv6: true${RESET}"
echo -e "${CYAN}--------------------------------${RESET}"

echo -e "\n${GREEN}服务器地址信息：${RESET}"

IPV4_ADDR=$(curl -s4 https://api.ipify.org)
if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
    IP_COUNTRY_IPV4=$(curl -s http://ipinfo.io/${IPV4_ADDR}/country)
    echo -e "${GREEN}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
fi

IPV6_ADDR=$(curl -s6 https://api64.ipify.org)
if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
    IP_COUNTRY_IPV6=$(curl -s https://ipapi.co/${IPV6_ADDR}/country/)
    echo -e "${GREEN}IPv6 地址: ${RESET}${IPV6_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV6}"
fi

echo -e "\n${GREEN}Surge 配置格式：${RESET}"
if [ ! -z "$IPV4_ADDR" ]; then
    generate_surge_config "$IPV4_ADDR" "$PORT" "$PSK" "$IP_COUNTRY_IPV4"
fi

if [ ! -z "$IPV6_ADDR" ]; then
    generate_surge_config "$IPV6_ADDR" "$PORT" "$PSK" "$IP_COUNTRY_IPV6"
fi

echo -e "\n${CYAN}安装完成！Snell ${SNELL_VERSION} 服务已启动。${RESET}"
```

}

# 初始检查

check_root
check_curl
check_bc

# 执行安装

install_snell
