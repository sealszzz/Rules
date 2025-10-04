#!/usr/bin/env bash
set -e

# ===================== 全局变量 =====================
SCRIPT_VERSION="2.0"

# 路径
SCRIPT_PATH=$(cd "$(dirname "$0")"; pwd)
SCRIPT_NAME=$(basename "$0")

# SS-Rust
INSTALL_DIR="/etc/ss-rust"
BINARY_PATH="/usr/local/bin/ss-rust"
CONFIG_PATH="/etc/ss-rust/config.json"
VERSION_FILE="/etc/ss-rust/ver.txt"

# Snell
SNELL_BINARY="/usr/local/bin/snell-server"
SNELL_CONF="/etc/snell/snell-server.conf"

# ShadowTLS
STLS_BINARY="/usr/local/bin/shadow-tls"
STLS_CONF="/etc/shadowtls/config.json"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PLAIN='\033[0m'

INFO="${GREEN}[信息]${PLAIN}"
ERROR="${RED}[错误]${PLAIN}"
SUCCESS="${GREEN}[成功]${PLAIN}"

# ===================== 通用函数 =====================
error_exit() {
    echo -e "${ERROR} $1" >&2
    exit 1
}

check_root() {
    if [[ $EUID != 0 ]]; then
        error_exit "请使用 root 权限运行该脚本"
    fi
}

wait_for_apt() {
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        echo -e "${YELLOW}等待 apt 释放锁...${PLAIN}"
        sleep 2
    done
}

check_and_install() {
    local tool=$1
    if ! command -v "$tool" &> /dev/null; then
        echo -e "${YELLOW}未检测到 $tool，正在安装...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y "$tool"
        elif [ -x "$(command -v yum)" ]; then
            yum install -y "$tool"
        else
            error_exit "不支持的包管理器，请手动安装 $tool"
        fi
    fi
}

for tool in curl jq wget unzip tar; do
    check_and_install "$tool"
done

# ===================== SSRust 部分 =====================
ss_generate_random_port() {
    shuf -i 30000-39999 -n 1
}

ss_generate_random_password() {
    # 32字节 base64
    local key
    key=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64)
    echo "$key"
}

ss_get_latest_version() {
    local version
    version=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases \
        | jq -r '[.[] | select(.prerelease==false) | .tag_name][0]')
    [[ -z "$version" ]] && error_exit "无法获取 Shadowsocks Rust 最新版本"
    echo "${version#v}"
}

ss_install() {
    echo -e "${INFO} 开始安装 Shadowsocks Rust..."
    local version=$(ss_get_latest_version)
    local arch=$(uname -m)
    local filename=""

    case "$arch" in
        x86_64) filename="shadowsocks-v${version}.x86_64-unknown-linux-gnu.tar.xz" ;;
        aarch64) filename="shadowsocks-v${version}.aarch64-unknown-linux-gnu.tar.xz" ;;
        armv7l) filename="shadowsocks-v${version}.armv7-unknown-linux-gnueabihf.tar.xz" ;;
        *) error_exit "不支持的架构: $arch" ;;
    esac

    mkdir -p "$INSTALL_DIR"
    cd /tmp
    wget -q --show-progress "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${version}/${filename}"
    tar -xf "$filename"
    mv ssserver "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    echo "$version" > "$VERSION_FILE"
    rm -rf "$filename"

    # 写入配置
    local port=$(ss_generate_random_port)
    local password=$(ss_generate_random_password)
    cat > "$CONFIG_PATH" <<EOF
{
    "server": "::",
    "server_port": ${port},
    "password": "${password}",
    "method": "2022-blake3-aes-256-gcm",
    "fast_open": true,
    "mode": "tcp_and_udp",
    "timeout": 300
}
EOF

    cat > /etc/systemd/system/ss-rust.service <<EOF
[Unit]
Description=Shadowsocks Rust Service
After=network.target

[Service]
ExecStart=${BINARY_PATH} -c ${CONFIG_PATH}
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ss-rust
    systemctl start ss-rust

    echo -e "${SUCCESS} Shadowsocks Rust 安装完成！"
}

ss_view_config() {
    [[ ! -f "$CONFIG_PATH" ]] && error_exit "未找到配置文件"
    local ip=$(curl -s4 ifconfig.me || echo "IP_Error")
    local port=$(jq -r '.server_port' "$CONFIG_PATH")
    local password=$(jq -r '.password' "$CONFIG_PATH")
    local method=$(jq -r '.method' "$CONFIG_PATH")

    echo -e "${INFO} Shadowsocks Rust 配置信息："
    echo -e " 地址: $ip"
    echo -e " 端口: $port"
    echo -e " 密码: $password"
    echo -e " 加密: $method"
    echo -e "\n=== Surge 配置 ==="
    echo "SSRUST = ss, ${ip}, ${port}, encrypt-method=${method}, password=${password}, udp-relay=true, tfo=true"
}

# ===================== Snell 部分 =====================
snell_get_latest_version() {
    curl -s https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell \
      | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+b?[0-9]*' | sort -V | tail -n1
}

snell_install() {
    local version=$(snell_get_latest_version)
    [[ -z "$version" ]] && version="5.0.0"

    local arch=$(uname -m)
    local file=""
    case "$arch" in
        x86_64) file="snell-server-v${version}-linux-amd64.zip" ;;
        aarch64) file="snell-server-v${version}-linux-aarch64.zip" ;;
        armv7l) file="snell-server-v${version}-linux-armv7l.zip" ;;
        i386|i686) file="snell-server-v${version}-linux-i386.zip" ;;
        *) error_exit "不支持的架构: $arch" ;;
    esac

    cd /tmp
    wget -q "https://dl.nssurge.com/snell/${file}"
    unzip -o "$file"
    mv snell-server "$SNELL_BINARY"
    chmod +x "$SNELL_BINARY"
    rm -f "$file"

    mkdir -p /etc/snell
    local port=$(shuf -i 30000-39999 -n1)
    local psk=$(openssl rand -base64 16)
    cat > "$SNELL_CONF" <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = true
EOF

    cat > /etc/systemd/system/snell.service <<EOF
[Unit]
Description=Snell Service
After=network.target

[Service]
ExecStart=${SNELL_BINARY} -c ${SNELL_CONF}
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell
    systemctl start snell

    echo -e "${SUCCESS} Snell 安装完成！"
}

snell_view_config() {
    [[ ! -f "$SNELL_CONF" ]] && error_exit "未找到 Snell 配置"
    local ip=$(curl -s4 ifconfig.me || echo "IP_Error")
    local port=$(grep 'listen' "$SNELL_CONF" | cut -d: -f2)
    local psk=$(grep 'psk' "$SNELL_CONF" | awk -F= '{print $2}' | xargs)

    echo -e "${INFO} Snell 配置信息："
    echo -e " 地址: $ip"
    echo -e " 端口: $port"
    echo -e " PSK : $psk"
    echo -e "\n=== Surge 配置 ==="
    echo "SNELL = snell, ${ip}, ${port}, psk=${psk}, version=5, reuse=true, tfo=true"
}

# ===================== ShadowTLS 部分 =====================
shadowtls_install() {
    echo -e "${INFO} 开始安装 ShadowTLS..."
    curl -L -o "$STLS_BINARY" https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-linux-amd64
    chmod +x "$STLS_BINARY"

    mkdir -p /etc/shadowtls
    local port=4433
    local password=$(openssl rand -hex 16)
    local sni="www.microsoft.com"
    cat > "$STLS_CONF" <<EOF
{
  "server": "::",
  "server_port": ${port},
  "password": "${password}",
  "tls": {
    "enabled": true,
    "sni": "${sni}"
  }
}
EOF

    cat > /etc/systemd/system/shadowtls.service <<EOF
[Unit]
Description=ShadowTLS Service
After=network.target

[Service]
ExecStart=${STLS_BINARY} -c ${STLS_CONF}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shadowtls
    systemctl start shadowtls

    echo -e "${SUCCESS} ShadowTLS 安装完成！"
}

shadowtls_view_config() {
    [[ ! -f "$STLS_CONF" ]] && error_exit "未找到 ShadowTLS 配置"
    local ip=$(curl -s4 ifconfig.me || echo "IP_Error")
    local port=$(jq -r '.server_port' "$STLS_CONF")
    local password=$(jq -r '.password' "$STLS_CONF")
    local sni=$(jq -r '.tls.sni' "$STLS_CONF")

    echo -e "${INFO} ShadowTLS 配置信息："
    echo -e " 地址: $ip"
    echo -e " 端口: $port"
    echo -e " 密码: $password"
    echo -e " SNI : $sni"
    echo -e "\n=== Surge 配置 ==="
    echo "STLS = snell, ${ip}, ${port}, psk=${password}, shadow-tls-sni=${sni}, shadow-tls-version=3, tfo=true"
}

# ===================== 主菜单 =====================
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}========= 三合一管理器 v${SCRIPT_VERSION} =========${PLAIN}"
        echo "1. 安装 Shadowsocks Rust"
        echo "2. 查看 Shadowsocks Rust 配置"
        echo "3. 安装 Snell"
        echo "4. 查看 Snell 配置"
        echo "5. 安装 ShadowTLS"
        echo "6. 查看 ShadowTLS 配置"
        echo "7. 退出"
        echo "===================================="
        read -rp "请输入选项 [1-7]: " choice
        case $choice in
            1) ss_install ;;
            2) ss_view_config ;;
            3) snell_install ;;
            4) snell_view_config ;;
            5) shadowtls_install ;;
            6) shadowtls_view_config ;;
            7) exit 0 ;;
            *) echo "无效选项" && sleep 1 ;;
        esac
        echo -e "\n按回车返回菜单..." && read
    done
}

check_root
main_menu
