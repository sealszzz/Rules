#!/bin/bash

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 定义系统路径
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/shadowtls"
SERVICE_FILE="${SYSTEMD_DIR}/shadowtls.service"

# 定义配置目录
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
USERS_DIR="${SNELL_CONF_DIR}/users"

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 安装必要的工具
install_requirements() {
    apt update
    apt install -y wget curl jq qrencode net-tools
}

# 获取最新版本
get_latest_version() {
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" | jq -r .tag_name)
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        echo -e "${RED}获取最新版本失败${RESET}"
        exit 1
    fi
    echo "$latest_version"
}

# 检查 SS 是否已安装
check_ssrust() {
    if [ ! -f "/usr/local/bin/ss-rust" ]; then
        return 1
    fi
    return 0
}

# 检查 Snell 是否已安装
check_snell() {
    if [ ! -f "/usr/local/bin/snell-server" ]; then
        return 1
    fi
    return 0
}

# 获取 SS 端口
get_ssrust_port() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local port
    port=$(jq -r '.server_port' "$ssrust_conf" 2>/dev/null)
    echo "$port"
}

# 获取 SS 密码
get_ssrust_password() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local password
    password=$(jq -r '.password' "$ssrust_conf" 2>/dev/null)
    echo "$password"
}

# 获取 SS 加密方式
get_ssrust_method() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local method
    method=$(jq -r '.method' "$ssrust_conf" 2>/dev/null)
    echo "$method"
}

# 获取 Snell 端口
get_snell_port() {
    if [ -f "${SNELL_CONF_FILE}" ]; then
        grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/.*::0:\([0-9]*\)/\1/p'
    fi
}

# 获取 Snell PSK（主配置）
get_snell_psk() {
    local snell_conf="/etc/snell/users/snell-main.conf"
    if [ ! -f "$snell_conf" ]; then
        return 1
    fi
    local psk
    psk=$(grep -E '^psk' "$snell_conf" | sed 's/psk = //')
    echo "$psk"
}

# 获取 Snell 指定端口配置的 PSK（若不存在则回退到主配置）
get_snell_config() {
    local port=$1
    local snell_conf="${USERS_DIR}/snell-${port}.conf"
    local main_conf="${USERS_DIR}/snell-main.conf"

    local psk
    psk=$(grep -E "^psk = " "$snell_conf" 2>/dev/null | sed 's/psk = //' || grep -E "^psk = " "$main_conf" 2>/dev/null | sed 's/psk = //')
    echo "$psk"
}

# 获取所有 Snell 用户配置（输出 port|psk 每行）
get_all_snell_users() {
    if [ ! -d "${USERS_DIR}" ]; then
        return 1
    fi

    # 主用户
    if [ -f "${SNELL_CONF_FILE}" ]; then
        local main_port main_psk
        main_port=$(grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        main_psk=$(grep -E '^psk' "${SNELL_CONF_FILE}" | awk -F'=' '{print $2}' | tr -d ' ')
        if [ -n "$main_port" ] && [ -n "$main_psk" ]; then
            echo "${main_port}|${main_psk}"
        fi
    fi

    # 其他用户
    for user_conf in "${USERS_DIR}"/snell-*.conf; do
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

# 获取 Snell 版本（返回 "5" 或 "4"）
get_snell_version() {
    if ! command -v snell-server &> /dev/null; then
        return 1
    fi

    local version_output
    version_output=$(snell-server --v 2>&1)

    if echo "$version_output" | grep -q "v5"; then
        echo "5"
    else
        echo "4"
    fi
}

# 获取服务器IP（优先 IPv4）
get_server_ip() {
    local ipv4 ipv6
    ipv4=$(curl -s -4 ip.sb 2>/dev/null)
    ipv6=$(curl -s -6 ip.sb 2>/dev/null)

    if [ -n "$ipv4" ]; then
        echo "$ipv4"
    elif [ -n "$ipv6" ]; then
        echo "$ipv6"
    else
        echo -e "${RED}无法获取服务器 IP${RESET}"
        return 1
    fi
    return 0
}

# 检查 shadow-tls 命令格式并显示帮助信息
check_shadowtls_command() {
    if [ ! -x "${INSTALL_DIR}/shadow-tls" ]; then
        echo -e "${YELLOW}未检测到 ${INSTALL_DIR}/shadow-tls 可执行文件，跳过帮助信息输出。${RESET}"
        return 1
    fi
    local help_output
    help_output=$(${INSTALL_DIR}/shadow-tls --help 2>&1)
    echo -e "${YELLOW}Shadow-tls 帮助信息：${RESET}"
    echo "$help_output"
    return 0
}

# 生成安全的 Base64（URL-safe，去掉 padding）
urlsafe_base64() {
    local input="$1"
    local b64
    b64=$(printf "%s" "$input" | base64 | tr -d '=' | tr '+/' '-_')
    printf "%s" "$b64"
}

# 生成随机端口
generate_random_port() {
    local min_port=10000
    local max_port=65535
    shuf -i "${min_port}-${max_port}" -n 1
}

# 检查端口是否被占用（使用 netstat；如果无 netstat 可替换为 ss）
check_port_usage() {
    local port=$1
    if command -v netstat &>/dev/null; then
        if netstat -tuln | grep -q ":${port}"; then
            return 0
        fi
    elif command -v ss &>/dev/null; then
        if ss -ltn | grep -q ":${port}"; then
            return 0
        fi
    else
        # 无法检测到 netstat/ss，保守认为未被占用
        return 1
    fi
    return 1
}

# 获取已使用的 ShadowTLS 端口（返回空格分隔）
get_used_stls_ports() {
    local used_ports=()
    # SS 服务
    local ss_service="${SYSTEMD_DIR}/shadowtls-ss.service"
    if [ -f "$ss_service" ]; then
        local ss_port
        ss_port=$(grep -oP '(?<=--listen ::0:)\d+' "$ss_service" 2>/dev/null)
        if [ -n "$ss_port" ]; then
            used_ports+=("$ss_port")
        fi
    fi

    # Snell 服务
    local snell_services
    snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ -n "$snell_services" ]; then
        while IFS= read -r service_file; do
            local port
            port=$(grep -oP '(?<=--listen ::0:)\d+' "$service_file" 2>/dev/null)
            if [ -n "$port" ]; then
                used_ports+=("$port")
            fi
        done <<< "$snell_services"
    fi

    echo "${used_ports[@]}"
}

# 验证并获取可用端口（如果传入空则随机挑选）
get_available_port() {
    local port="$1"
    local used_ports
    IFS=' ' read -r -a used_ports <<< "$(get_used_stls_ports)"

    if [ -n "$port" ]; then
        for used in "${used_ports[@]}"; do
            if [ "$port" = "$used" ]; then
                echo -e "${RED}端口 ${port} 已被其他 ShadowTLS 服务使用${RESET}"
                return 1
            fi
        done
        if check_port_usage "$port"; then
            echo -e "${RED}端口 ${port} 已被其他服务占用${RESET}"
            return 1
        fi
        echo "$port"
        return 0
    fi

    local attempts=0
    while [ $attempts -lt 20 ]; do
        local random_port
        random_port=$(generate_random_port)
        local is_used=0
        for used in "${used_ports[@]}"; do
            if [ "$random_port" = "$used" ]; then
                is_used=1
                break
            fi
        done
        if [ $is_used -eq 0 ] && ! check_port_usage "$random_port"; then
            echo "$random_port"
            return 0
        fi
        attempts=$((attempts + 1))
    done

    echo -e "${RED}无法找到可用端口${RESET}"
    return 1
}

# 生成 SS 链接和配置（并画二维码）
generate_ss_links() {
    local server_ip=$1
    local listen_port=$2
    local ssrust_password=$3
    local ssrust_method=$4
    local stls_password=$5
    local stls_sni=$6
    local backend_port=$7

    echo -e "\n${YELLOW}=== 服务器配置 ===${RESET}"
    echo -e "服务器IP：${server_ip}"
    echo -e "\nShadowsocks 配置："
    echo -e "  - 端口：${backend_port}"
    echo -e "  - 加密方式：${ssrust_method}"
    echo -e "  - 密码：${ssrust_password}"
    echo -e "\nShadowTLS 配置："
    echo -e "  - 端口：${listen_port}"
    echo -e "  - 密码：${stls_password}"
    echo -e "  - SNI：${stls_sni}"
    echo -e "  - 版本：3"

    # 生成 SS + ShadowTLS 合并链接
    local userinfo
    userinfo=$(printf "%s:%s" "${ssrust_method}" "${ssrust_password}" | base64 | tr -d '\n')
    local shadow_tls_config
    shadow_tls_config=$(printf '{"version":"3","password":"%s","host":"%s","port":"%s","address":"%s"}' "${stls_password}" "${stls_sni}" "${listen_port}" "${server_ip}")
    local shadow_tls_base64
    shadow_tls_base64=$(printf "%s" "${shadow_tls_config}" | base64 | tr -d '\n')
    local ss_url="ss://${userinfo}@${server_ip}:${backend_port}?shadow-tls=${shadow_tls_base64}#SS-${server_ip}"

    echo -e "\n${YELLOW}=== Surge 配置 ===${RESET}"
    echo -e "SS-${server_ip} = ss, ${server_ip}, ${listen_port}, encrypt-method=${ssrust_method}, password=${ssrust_password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${stls_sni}, shadow-tls-version=3, udp-relay=true"

    echo -e "\n${YELLOW}=== Shadowrocket 配置说明 ===${RESET}"
    echo -e "1. 添加 Shadowsocks 节点："
    echo -e "   - 类型：Shadowsocks"
    echo -e "   - 地址：${server_ip}"
    echo -e "   - 端口：${backend_port}"
    echo -e "   - 加密方法：${ssrust_method}"
    echo -e "   - 密码：${ssrust_password}"

    echo -e "\n2. 添加 ShadowTLS 节点："
    echo -e "   - 类型：ShadowTLS"
    echo -e "   - 地址：${server_ip}"
    echo -e "   - 端口：${listen_port}"
    echo -e "   - 密码：${stls_password}"
    echo -e "   - SNI：${stls_sni}"
    echo -e "   - 版本：3"

    echo -e "\n${YELLOW}=== Shadowrocket分享链接 ===${RESET}"
    echo -e "${GREEN}SS + ShadowTLS 链接：${RESET}${ss_url}"

    if command -v qrencode &>/dev/null; then
        echo -e "\n${YELLOW}=== Shadowrocket二维码 ===${RESET}"
        qrencode -t UTF8 "${ss_url}"
    fi

    echo -e "\n${YELLOW}=== Clash Meta 配置 ===${RESET}"
    echo -e "proxies:"
    echo -e "  - name: SS-${server_ip}"
    echo -e "    type: ss"
    echo -e "    server: ${server_ip}"
    echo -e "    port: ${listen_port}"
    echo -e "    cipher: ${ssrust_method}"
    echo -e "    password: \"${ssrust_password}\""
    echo -e "    plugin: shadow-tls"
    echo -e "    plugin-opts:"
    echo -e "      host: \"${stls_sni}\""
    echo -e "      password: \"${stls_password}\""
    echo -e "      version: 3"
}

# 生成 Snell 链接和配置
generate_snell_links() {
    local server_ip=$1
    local listen_port=$2
    local snell_psk=$3
    local stls_password=$4
    local stls_sni=$5
    local backend_port=$6

    local snell_version
    snell_version=$(get_snell_version)

    echo -e "\n${YELLOW}=== 服务器配置 ===${RESET}"
    echo -e "服务器IP：${server_ip}"
    echo -e "\nSnell 配置："
    echo -e "  - 端口：${backend_port}"
    echo -e "  - PSK：${snell_psk}"
    echo -e "  - 版本：${snell_version}"
    echo -e "\nShadowTLS 配置："
    echo -e "  - 端口：${listen_port}"
    echo -e "  - 密码：${stls_password}"
    echo -e "  - SNI：${stls_sni}"
    echo -e "  - 版本：3"

    echo -e "\n${YELLOW}=== Surge 配置 ===${RESET}"
    if [ "$snell_version" = "5" ]; then
        echo -e "Snell v4 + ShadowTLS = snell, ${server_ip}, ${listen_port}, psk = ${snell_psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_sni}, shadow-tls-version = 3"
        echo -e "Snell v5 + ShadowTLS = snell, ${server_ip}, ${listen_port}, psk = ${snell_psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_sni}, shadow-tls-version = 3"
    else
        echo -e "Snell + ShadowTLS = snell, ${server_ip}, ${listen_port}, psk = ${snell_psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_sni}, shadow-tls-version = 3"
    fi
}

# 创建服务文件的模板
create_shadowtls_service() {
    local service_type=$1  # ss 或 snell
    local port=$2
    local listen_port=$3
    local tls_domain=$4
    local password=$5
    local service_file description identifier

    if [ "$service_type" = "ss" ]; then
        service_file="${SYSTEMD_DIR}/shadowtls-ss.service"
        description="Shadow-TLS Server Service for Shadowsocks"
        identifier="shadow-tls-ss"
    else
        service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
        description="Shadow-TLS Server Service for Snell (Port: ${port})"
        identifier="shadow-tls-snell-${port}"
    fi

    cat > "$service_file" << EOF
[Unit]
Description=${description}
Documentation=man:sstls-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment=RUST_BACKTRACE=1
Environment=RUST_LOG=info
ExecStart=${INSTALL_DIR}/shadow-tls --v3 server --listen ::0:${listen_port} --server 127.0.0.1:${port} --tls ${tls_domain} --password ${password}
StandardOutput=append:/var/log/shadowtls-${identifier}.log
StandardError=append:/var/log/shadowtls-${identifier}.log
SyslogIdentifier=${identifier}
Restart=always
RestartSec=3

# 性能优化参数
LimitNOFILE=65535
CPUAffinity=0
Nice=0
IOSchedulingClass=realtime
IOSchedulingPriority=0
MemoryLimit=512M
CPUQuota=50%
LimitCORE=infinity
LimitRSS=infinity
LimitNPROC=65535
LimitAS=infinity
SystemCallFilter=@system-service
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# 系统优化参数
Environment=RUST_THREADS=1
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
Environment=RUST_LOG_LEVEL=info
Environment=RUST_LOG_TARGET=journal
Environment=RUST_LOG_FORMAT=json
Environment=RUST_LOG_FILTER=info,shadow_tls=info

[Install]
WantedBy=multi-user.target
EOF

    # 创建日志文件并设置权限
    touch "/var/log/shadowtls-${identifier}.log"
    chmod 640 "/var/log/shadowtls-${identifier}.log"
    chown root:root "/var/log/shadowtls-${identifier}.log"
}

# 安装 ShadowTLS
install_shadowtls() {
    echo -e "${CYAN}正在安装 ShadowTLS...${RESET}"

    local has_ss=false has_snell=false configure_ss configure_snell
    if check_ssrust; then
        has_ss=true
        echo -e "${GREEN}检测到已安装 Shadowsocks Rust${RESET}"
    fi
    if check_snell; then
        has_snell=true
        echo -e "${GREEN}检测到已安装 Snell${RESET}"
    fi

    if ! $has_ss && ! $has_snell; then
        echo -e "${RED}未检测到 Shadowsocks Rust 或 Snell，请先安装其中一个${RESET}"
        return 1
    fi

    # 架构判断
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64) arch="x86_64-unknown-linux-musl" ;;
        aarch64) arch="aarch64-unknown-linux-musl" ;;
        *)
            echo -e "${RED}不支持的系统架构: $arch${RESET}"
            exit 1
            ;;
    esac

    # 获取最新版本并下载
    local version
    version=$(get_latest_version)
    local download_url
    download_url="https://github.com/ihciah/shadow-tls/releases/download/${version}/shadow-tls-${arch}"
    wget "$download_url" -O "/tmp/shadow-tls.tmp"
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 ShadowTLS 失败${RESET}"
        exit 1
    fi
    mv "/tmp/shadow-tls.tmp" "$INSTALL_DIR/shadow-tls"
    chmod +x "$INSTALL_DIR/shadow-tls"

    # 随机密码 & TLS 域名
    local password tls_domain
    password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    read -rp "请输入 TLS 伪装域名 (直接回车默认为 www.microsoft.com): " tls_domain
    if [ -z "$tls_domain" ]; then
        tls_domain="www.microsoft.com"
    fi

    # 选择要配置的协议
    while true; do
        echo -e "\n${YELLOW}请选择要配置的协议：${RESET}"
        echo -e "1. 为 Shadowsocks 配置 ShadowTLS"
        echo -e "2. 为 Snell 配置 ShadowTLS"
        echo -e "3. 为两者都配置 ShadowTLS"
        echo -e "0. 退出"
        read -rp "请选择 [0-3]: " protocol_choice

        case "$protocol_choice" in
            0) return 0 ;;
            1)
                if ! $has_ss; then
                    echo -e "${RED}未安装 Shadowsocks${RESET}"
                    continue
                fi
                configure_ss=true
                configure_snell=false
                break
                ;;
            2)
                if ! $has_snell; then
                    echo -e "${RED}未安装 Snell${RESET}"
                    continue
                fi
                configure_ss=false
                configure_snell=true
                break
                ;;
            3)
                if ! $has_ss || ! $has_snell; then
                    echo -e "${RED}需要同时安装 Shadowsocks 和 Snell${RESET}"
                    continue
                fi
                configure_ss=true
                configure_snell=true
                break
                ;;
            *)
                echo -e "${RED}无效的选择${RESET}"
                ;;
        esac
    done

    # 配置 Shadowsocks 的 ShadowTLS
    local ss_listen_port ss_port
    if [ "$configure_ss" = true ]; then
        echo -e "\n${YELLOW}配置 Shadowsocks 的 ShadowTLS...${RESET}"
        while true; do
            read -rp "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): " ss_listen_port
            ss_listen_port=$(get_available_port "$ss_listen_port") || { echo -e "${YELLOW}请重新输入端口${RESET}"; continue; }
            break
        done
        echo -e "${GREEN}将使用端口: ${ss_listen_port}${RESET}"
        ss_port=$(get_ssrust_port)
        create_shadowtls_service "ss" "$ss_port" "$ss_listen_port" "$tls_domain" "$password"
        systemctl daemon-reload
        systemctl start shadowtls-ss
        systemctl enable shadowtls-ss
    fi

    # 配置 Snell 的 ShadowTLS
    if [ "$configure_snell" = true ]; then
        echo -e "\n${YELLOW}配置 Snell 的 ShadowTLS...${RESET}"
        local user_configs
        user_configs=$(get_all_snell_users)
        if [ -z "$user_configs" ]; then
            echo -e "${RED}未找到有效的 Snell 用户配置${RESET}"
            return 1
        fi

        # 列出端口
        echo -e "\n${YELLOW}当前的 Snell 端口列表：${RESET}"
        local port_list=()
        local idx=0
        while IFS='|' read -r port psk; do
            if [ -n "$port" ]; then
                port_list+=("$port")
                idx=$((idx + 1))
                if [ "$port" = "$(get_snell_port)" ]; then
                    echo -e "${GREEN}${idx}. ${port} (主用户)${RESET}"
                else
                    echo -e "${GREEN}${idx}. ${port}${RESET}"
                fi
            fi
        done <<< "$user_configs"

        echo -e "\n${YELLOW}请选择要配置的端口：${RESET}"
        echo -e "1-${#port_list[@]}. 选择单个端口"
        echo -e "0. 为所有端口配置 ShadowTLS"
        read -rp "请选择: " port_choice

        if [ "$port_choice" = "0" ]; then
            for port in "${port_list[@]}"; do
                echo -e "\n${YELLOW}为 Snell 端口 ${port} 配置 ShadowTLS${RESET}"
                local stls_port
                while true; do
                    read -rp "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): " stls_port
                    stls_port=$(get_available_port "$stls_port") || { echo -e "${YELLOW}请重新输入端口${RESET}"; continue; }
                    break
                done
                echo -e "${GREEN}将使用端口: ${stls_port}${RESET}"
                create_shadowtls_service "snell" "$port" "$stls_port" "$tls_domain" "$password"
                systemctl daemon-reload
                systemctl start "shadowtls-snell-${port}"
                systemctl enable "shadowtls-snell-${port}"

                local server_ip psk
                server_ip=$(get_server_ip)
                psk=$(grep -E "^psk = " "/etc/snell/users/snell-${port}.conf" 2>/dev/null | sed 's/psk = //' || grep -E "^psk = " "/etc/snell/users/snell-main.conf" 2>/dev/null | sed 's/psk = //')
                generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${port}"
            done
        elif [[ "$port_choice" =~ ^[0-9]+$ ]] && [ "$port_choice" -ge 1 ] && [ "$port_choice" -le ${#port_list[@]} ]; then
            local selected_port="${port_list[$((port_choice-1))]}"
            echo -e "\n${YELLOW}为 Snell 端口 ${selected_port} 配置 ShadowTLS${RESET}"
            local stls_port
            while true; do
                read -rp "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): " stls_port
                stls_port=$(get_available_port "$stls_port") || { echo -e "${YELLOW}请重新输入端口${RESET}"; continue; }
                break
            done
            create_shadowtls_service "snell" "$selected_port" "$stls_port" "$tls_domain" "$password"
            systemctl daemon-reload
            systemctl start "shadowtls-snell-${selected_port}"
            systemctl enable "shadowtls-snell-${selected_port}"

            local server_ip psk
            server_ip=$(get_server_ip)
            psk=$(grep -E "^psk = " "/etc/snell/users/snell-${selected_port}.conf" 2>/dev/null | sed 's/psk = //' || grep -E "^psk = " "/etc/snell/users/snell-main.conf" 2>/dev/null | sed 's/psk = //')
            generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${selected_port}"
        else
            echo -e "${RED}无效的选择${RESET}"
            return 1
        fi
    fi

    systemctl daemon-reload

    local server_ip
    server_ip=$(get_server_ip)
    echo -e "\n${GREEN}=== ShadowTLS 安装成功 ===${RESET}"

    if [ "$configure_ss" = true ]; then
        local ssrust_password ssrust_method ss_port
        ssrust_password=$(get_ssrust_password)
        ssrust_method=$(get_ssrust_method)
        ss_port=$(get_ssrust_port)
        generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
    fi

    if [ "$configure_snell" = true ]; then
        while IFS='|' read -r port psk; do
            if [ -n "$port" ]; then
                local service_file stls_port
                service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
                if [ -f "$service_file" ]; then
                    stls_port=$(grep -oP '(?<=--listen ::0:)\d+' "$service_file" 2>/dev/null)
                    generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${port}"
                fi
            fi
        done <<< "$user_configs"
    fi

    echo -e "\n${GREEN}服务已启动并设置为开机自启${RESET}"
}

# 卸载 ShadowTLS
uninstall_shadowtls() {
    echo -e "${CYAN}正在卸载 ShadowTLS...${RESET}"

    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
        systemctl stop shadowtls-ss 2>/dev/null
        systemctl disable shadowtls-ss 2>/dev/null
        rm -f "${SYSTEMD_DIR}/shadowtls-ss.service"
    fi

    local snell_services
    snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ -n "$snell_services" ]; then
        while IFS= read -r service_file; do
            local service_name
            service_name=$(basename "$service_file")
            systemctl stop "$service_name" 2>/dev/null
            systemctl disable "$service_name" 2>/dev/null
            rm -f "$service_file"
        done <<< "$snell_services"
    fi

    rm -f "$INSTALL_DIR/shadow-tls"
    systemctl daemon-reload
    echo -e "${GREEN}ShadowTLS 已成功卸载${RESET}"
}

# 查看配置（显示已配置的 ShadowTLS 节点及状态）
view_config() {
    echo -e "${CYAN}正在获取配置信息...${RESET}"

    local ss_service="${SYSTEMD_DIR}/shadowtls-ss.service"
    local snell_services
    snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)

    if [ ! -f "$ss_service" ] && [ -z "$snell_services" ]; then
        echo -e "${RED}ShadowTLS 未安装${RESET}"
        return 1
    fi

    local server_ip
    server_ip=$(get_server_ip)

    if [ -f "$ss_service" ] && check_ssrust; then
        echo -e "\n${YELLOW}=== Shadowsocks + ShadowTLS 配置 ===${RESET}"
        local ss_listen_port tls_domain password ss_port ssrust_password ssrust_method
        ss_listen_port=$(grep -oP '(?<=--listen ::0:)\d+' "$ss_service" 2>/dev/null)
        tls_domain=$(grep -oP '(?<=--tls )[^ ]+' "$ss_service" 2>/dev/null)
        password=$(grep -oP '(?<=--password )[^ ]+' "$ss_service" 2>/dev/null)
        ss_port=$(get_ssrust_port)
        ssrust_password=$(get_ssrust_password)
        ssrust_method=$(get_ssrust_method)
        if [ -n "$ss_listen_port" ] && [ -n "$tls_domain" ] && [ -n "$password" ]; then
            generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
        else
            echo -e "${RED}SS 配置文件不完整或已损坏${RESET}"
        fi
    fi

    if [ -n "$snell_services" ] && check_snell; then
        echo -e "\n${YELLOW}=== Snell + ShadowTLS 配置 ===${RESET}"
        local user_configs
        user_configs=$(get_all_snell_users)
        if [ -n "$user_configs" ]; then
            declare -A processed_ports
            while IFS='|' read -r port psk; do
                if [ -n "$port" ] && [ -z "${processed_ports[$port]}" ]; then
                    processed_ports[$port]=1
                    local service_file exec_line stls_port stls_password stls_domain
                    service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
                    if [ -f "$service_file" ]; then
                        exec_line=$(grep "ExecStart=" "$service_file" 2>/dev/null)
                        stls_port=$(echo "$exec_line" | grep -oP '(?<=--listen ::0:)\d+' 2>/dev/null)
                        stls_password=$(echo "$exec_line" | grep -oP '(?<=--password )[^ ]+' 2>/dev/null)
                        stls_domain=$(echo "$exec_line" | grep -oP '(?<=--tls )[^ ]+' 2>/dev/null)

                        if [ "$port" = "$(get_snell_port)" ]; then
                            echo -e "\n${GREEN}主用户配置：${RESET}"
                        else
                            echo -e "\n${GREEN}用户配置 (Snell 端口: ${port}):${RESET}"
                        fi

                        if [ -n "$stls_port" ] && [ -n "$stls_password" ] && [ -n "$stls_domain" ]; then
                            echo -e "${YELLOW}Snell 配置：${RESET}"
                            echo -e "  - 端口：${port}"
                            echo -e "  - PSK：${psk}"
                            echo -e "\n${YELLOW}ShadowTLS 配置：${RESET}"
                            echo -e "  - 监听端口：${stls_port}"
                            echo -e "  - 密码：${stls_password}"
                            echo -e "  - SNI：${stls_domain}"
                            echo -e "  - 版本：3"

                            echo -e "\n${GREEN}Surge 配置：${RESET}"
                            local snell_version
                            snell_version=$(get_snell_version)
                            if [ "$snell_version" = "5" ]; then
                                echo -e "Snell v4 + ShadowTLS = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3"
                                echo -e "Snell v5 + ShadowTLS = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3"
                            else
                                echo -e "Snell + ShadowTLS = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3"
                            fi

                            local service_status
                            service_status=$(systemctl is-active "shadowtls-snell-${port}")
                            if [ "$service_status" = "active" ]; then
                                echo -e "\n${GREEN}服务状态：正在运行${RESET}"
                                # 检查端口占用情况
                                if check_port_usage "$stls_port"; then
                                    echo -e "${YELLOW}端口 ${stls_port} 被占用，显示占用列表：${RESET}"
                                    if command -v netstat &>/dev/null; then
                                        netstat -tuln | grep ":${stls_port}"
                                    else
                                        ss -ltn | grep ":${stls_port}"
                                    fi
                                fi
                            else
                                echo -e "\n${RED}服务状态：未运行${RESET}"
                                echo -e "${YELLOW}请尝试以下命令重启服务：${RESET}"
                                echo -e "systemctl restart shadowtls-snell-${port}"
                            fi
                        else
                            echo -e "${RED}配置文件不完整或已损坏${RESET}"
                        fi
                    else
                        echo -e "\n${YELLOW}未找到用户 (端口: ${port}) 的 ShadowTLS 配置${RESET}"
                    fi
                fi
            done <<< "$user_configs"
        else
            echo -e "\n${YELLOW}未找到有效的 Snell 用户配置${RESET}"
        fi
    fi

    # 显示服务状态摘要
    echo -e "\n${YELLOW}=== ShadowTLS 服务状态 ===${RESET}"
    if [ -f "$ss_service" ]; then
        echo -e "\n${YELLOW}SS 服务状态：${RESET}"
        systemctl status shadowtls-ss --no-pager
        if [ "$(systemctl is-active shadowtls-ss)" != "active" ]; then
            echo -e "\n${YELLOW}SS 服务未运行，请尝试以下命令重启：${RESET}"
            echo -e "systemctl restart shadowtls-ss"
        fi
    fi

    if [ -n "$snell_services" ]; then
        echo -e "\n${YELLOW}Snell 服务状态：${RESET}"
        declare -A shown_services
        while IFS= read -r service_file; do
            local port
            port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
            if [ -z "${shown_services[$port]}" ]; then
                shown_services[$port]=1
                echo -e "\n${GREEN}Snell 端口 ${port} 的 ShadowTLS 服务状态：${RESET}"
                systemctl status "shadowtls-snell-${port}" --no-pager
                if [ "$(systemctl is-active shadowtls-snell-${port})" != "active" ]; then
                    echo -e "\n${YELLOW}服务未运行，请尝试以下命令重启：${RESET}"
                    echo -e "systemctl restart shadowtls-snell-${port}"
                fi
            fi
        done <<< "$snell_services"
    fi
}

# 新增 ShadowTLS 配置（交互）
add_shadowtls_config() {
    echo -e "${CYAN}新增 ShadowTLS 配置...${RESET}"

    local has_ss=false has_snell=false has_ss_stls=false
    if check_ssrust; then
        has_ss=true
        echo -e "${GREEN}检测到已安装 Shadowsocks Rust${RESET}"
        if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
            has_ss_stls=true
            echo -e "${YELLOW}已存在 Shadowsocks 的 ShadowTLS 配置${RESET}"
        fi
    fi
    if check_snell; then
        has_snell=true
        echo -e "${GREEN}检测到已安装 Snell${RESET}"
    fi
    if ! $has_ss && ! $has_snell; then
        echo -e "${RED}未检测到 Shadowsocks Rust 或 Snell，请先安装其中一个${RESET}"
        return 1
    fi

    while true; do
        echo -e "\n${YELLOW}请选择要新增配置的协议：${RESET}"
        if $has_ss && ! $has_ss_stls; then
            echo -e "1. 为 Shadowsocks 新增 ShadowTLS 配置"
        fi
        if $has_snell; then
            echo -e "2. 为 Snell 新增 ShadowTLS 配置"
        fi
        echo -e "0. 返回"
        read -rp "请选择: " choice

        case "$choice" in
            0) return 0 ;;
            1)
                if ! $has_ss || $has_ss_stls; then
                    echo -e "${RED}无效的选择${RESET}"
                    continue
                fi
                local password tls_domain ss_listen_port ss_port server_ip ssrust_password ssrust_method
                password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
                read -rp "请输入 TLS 伪装域名 (直接回车默认为 www.microsoft.com): " tls_domain
                tls_domain=${tls_domain:-www.microsoft.com}

                while true; do
                    read -rp "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): " ss_listen_port
                    ss_listen_port=$(get_available_port "$ss_listen_port") || { echo -e "${YELLOW}请重新输入端口${RESET}"; continue; }
                    break
                done

                ss_port=$(get_ssrust_port)
                create_shadowtls_service "ss" "$ss_port" "$ss_listen_port" "$tls_domain" "$password"
                systemctl daemon-reload
                systemctl start shadowtls-ss
                systemctl enable shadowtls-ss

                server_ip=$(get_server_ip)
                ssrust_password=$(get_ssrust_password)
                ssrust_method=$(get_ssrust_method)
                generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
                break
                ;;
            2)
                if ! $has_snell; then
                    echo -e "${RED}无效的选择${RESET}"
                    continue
                fi

                local password tls_domain user_configs port_list port_count port_choice selected_port stls_port server_ip psk
                password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
                read -rp "请输入 TLS 伪装域名 (直接回车默认为 www.microsoft.com): " tls_domain
                tls_domain=${tls_domain:-www.microsoft.com}

                user_configs=$(get_all_snell_users)
                if [ -z "$user_configs" ]; then
                    echo -e "${RED}未找到有效的 Snell 用户配置${RESET}"
                    return 1
                fi

                echo -e "\n${YELLOW}未配置 ShadowTLS 的 Snell 端口列表：${RESET}"
                port_list=()
                port_count=0
                while IFS='|' read -r port psk; do
                    if [ -n "$port" ] && [ ! -f "${SYSTEMD_DIR}/shadowtls-snell-${port}.service" ]; then
                        port_list+=("$port")
                        port_count=$((port_count+1))
                        if [ "$port" = "$(get_snell_port)" ]; then
                            echo -e "${GREEN}${port_count}. ${port} (主用户)${RESET}"
                        else
                            echo -e "${GREEN}${port_count}. ${port}${RESET}"
                        fi
                    fi
                done <<< "$user_configs"

                if [ ${#port_list[@]} -eq 0 ]; then
                    echo -e "${YELLOW}所有 Snell 端口都已配置 ShadowTLS${RESET}"
                    return 0
                fi

                echo -e "\n${YELLOW}请选择要配置的端口：${RESET}"
                echo -e "1-${#port_list[@]}. 选择单个端口"
                echo -e "0. 为所有未配置端口配置 ShadowTLS"
                read -rp "请选择: " port_choice

                if [ "$port_choice" = "0" ]; then
                    for port in "${port_list[@]}"; do
                        echo -e "\n${YELLOW}为 Snell 端口 ${port} 配置 ShadowTLS${RESET}"
                        while true; do
                            read -rp "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): " stls_port
                            stls_port=$(get_available_port "$stls_port") || { echo -e "${YELLOW}请重新输入端口${RESET}"; continue; }
                            break
                        done
                        create_shadowtls_service "snell" "$port" "$stls_port" "$tls_domain" "$password"
                        systemctl daemon-reload
                        systemctl start "shadowtls-snell-${port}"
                        systemctl enable "shadowtls-snell-${port}"

                        server_ip=$(get_server_ip)
                        psk=$(grep -E "^psk = " "/etc/snell/users/snell-${port}.conf" 2>/dev/null | sed 's/psk = //' || grep -E "^psk = " "/etc/snell/users/snell-main.conf" 2>/dev/null | sed 's/psk = //')
                        generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${port}"
                    done
                elif [[ "$port_choice" =~ ^[0-9]+$ ]] && [ "$port_choice" -ge 1 ] && [ "$port_choice" -le ${#port_list[@]} ]; then
                    selected_port="${port_list[$((port_choice-1))]}"
                    echo -e "\n${YELLOW}为 Snell 端口 ${selected_port} 配置 ShadowTLS${RESET}"
                    while true; do
                        read -rp "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): " stls_port
                        stls_port=$(get_available_port "$stls_port") || { echo -e "${YELLOW}请重新输入端口${RESET}"; continue; }
                        break
                    done
                    create_shadowtls_service "snell" "$selected_port" "$stls_port" "$tls_domain" "$password"
                    systemctl daemon-reload
                    systemctl start "shadowtls-snell-${selected_port}"
                    systemctl enable "shadowtls-snell-${selected_port}"

                    server_ip=$(get_server_ip)
                    psk=$(grep -E "^psk = " "/etc/snell/users/snell-${selected_port}.conf" 2>/dev/null | sed 's/psk = //' || grep -E "^psk = " "/etc/snell/users/snell-main.conf" 2>/dev/null | sed 's/psk = //')
                    generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${selected_port}"
                else
                    echo -e "${RED}无效的选择${RESET}"
                    continue
                fi
                break
                ;;
            *)
                echo -e "${RED}无效的选择${RESET}"
                ;;
        esac
    done

    systemctl daemon-reload
    echo -e "\n${GREEN}新增配置完成${RESET}"
}

# 重启 ShadowTLS 服务
restart_shadowtls_services() {
    echo -e "${CYAN}重启 ShadowTLS 服务...${RESET}"

    local has_services=false

    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
        has_services=true
        echo -e "\n${YELLOW}重启 Shadowsocks 的 ShadowTLS 服务...${RESET}"
        systemctl restart shadowtls-ss
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Shadowsocks ShadowTLS 服务重启成功${RESET}"
        else
            echo -e "${RED}Shadowsocks ShadowTLS 服务重启失败${RESET}"
        fi
    fi

    local snell_services
    snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ -n "$snell_services" ]; then
        has_services=true
        echo -e "\n${YELLOW}重启 Snell 的 ShadowTLS 服务...${RESET}"
        while IFS= read -r service_file; do
            local port
            port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
            echo -e "重启端口 ${port} 的服务..."
            systemctl restart "shadowtls-snell-${port}"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}端口 ${port} 的服务重启成功${RESET}"
            else
                echo -e "${RED}端口 ${port} 的服务重启失败${RESET}"
            fi
        done <<< "$snell_services"
    fi

    if ! $has_services; then
        echo -e "${RED}未找到任何 ShadowTLS 服务${RESET}"
        return 1
    fi

    echo -e "\n${GREEN}所有服务重启完成${RESET}"

    echo -e "\n${YELLOW}服务状态：${RESET}"
    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
        echo -e "\n${CYAN}Shadowsocks ShadowTLS 服务状态：${RESET}"
        systemctl status shadowtls-ss --no-pager
    fi

    if [ -n "$snell_services" ]; then
        while IFS= read -r service_file; do
            local port
            port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
            echo -e "\n${CYAN}Snell 端口 ${port} 的 ShadowTLS 服务状态：${RESET}"
            systemctl status "shadowtls-snell-${port}" --no-pager
        done <<< "$snell_services"
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n${CYAN}ShadowTLS 管理菜单${RESET}"
        echo -e "${YELLOW}1. 安装 ShadowTLS${RESET}"
        echo -e "${YELLOW}2. 卸载 ShadowTLS${RESET}"
        echo -e "${YELLOW}3. 查看配置${RESET}"
        echo -e "${YELLOW}4. 新增配置${RESET}"
        echo -e "${YELLOW}5. 重启服务${RESET}"
        echo -e "${YELLOW}6. 返回上级菜单${RESET}"
        echo -e "${YELLOW}0. 退出${RESET}"

        read -rp "请选择操作 [0-6]: " choice

        case "$choice" in
            1) install_shadowtls ;;
            2) uninstall_shadowtls ;;
            3) view_config ;;
            4) add_shadowtls_config ;;
            5) restart_shadowtls_services ;;
            6) return 0 ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效的选择${RESET}" ;;
        esac
    done
}

# 检查root权限并启动菜单（仅在直接运行时）
check_root
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu
fi
