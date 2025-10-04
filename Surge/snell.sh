#!/bin/bash

# ========================= 颜色与版本 =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 脚本版本
current_version="5.0"

# ========================= 全局/路径 =========================
SNELL_VERSION=""  # 形如 v5.0.0b3 或 v6.0.0.0

INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
SYSTEMD_SERVICE_FILE="${SYSTEMD_DIR}/snell.service"

# 旧配置（迁移用）
OLD_SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
OLD_SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"

# ========================= 基础工具与环境 =========================
wait_for_apt() {
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        echo -e "${YELLOW}等待其他 apt 进程完成...${RESET}"
        sleep 1
    done
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

check_curl() {
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y curl
        elif [ -x "$(command -v yum)" ]; then
            yum install -y curl
        else
            echo -e "${RED}未支持的包管理器，无法安装 curl。请手动安装 curl。${RESET}"
            exit 1
        fi
    fi
}

check_bc() {
    if ! command -v bc &> /dev/null; then
        echo -e "${YELLOW}未检测到 bc，正在安装...${RESET}"
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y bc
        elif [ -x "$(command -v yum)" ]; then
            yum install -y bc
        else
            echo -e "${RED}未支持的包管理器，无法安装 bc。请手动安装 bc。${RESET}"
            exit 1
        fi
    fi
}

check_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}未检测到 jq，正在安装...${RESET}"
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y jq
        elif [ -x "$(command -v yum)" ]; then
            yum install -y jq
        else
            echo -e "${RED}未支持的包管理器，无法安装 jq。请手动安装 jq。${RESET}"
            exit 1
        fi
    fi
}

# ========================= 版本抓取（KB页面，优先 beta，无兜底） =========================
get_latest_snell_version() {
  local url="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"
  local html v_beta v_stable
  html=$(curl -fsSL --connect-timeout 5 -m 10 "$url") || return 1

  # 先找 beta（X.Y.ZbN），优先
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

  # 无 beta 时，取数值最大的稳定版（支持 X.Y.Z 或 X.Y.Z.W）
  v_stable=$(printf '%s' "$html" \
    | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' \
    | sed -E 's/^snell-server-v//' \
    | sort -V | tail -n1)

  if [ -n "$v_stable" ]; then
    echo "v${v_stable}"
    return 0
  fi

  # 不兜底：抓不到就返回非零
  return 1
}

# ========================= 下载 URL 拼接 =========================
get_snell_download_url() {
    local version="$1"
    local arch
    arch=$(uname -m)

    case ${arch} in
        "x86_64"|"amd64")
            echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-amd64.zip"
            ;;
        "i386"|"i686")
            echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-i386.zip"
            ;;
        "aarch64"|"arm64")
            echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-aarch64.zip"
            ;;
        "armv7l"|"armv7")
            echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-armv7l.zip"
            ;;
        *)
            echo -e "${RED}不支持的架构: ${arch}${RESET}" >&2
            return 1
            ;;
    esac
}

# ========================= 版本与配置相关 =========================
detect_installed_snell_version() {
    if command -v snell-server &> /dev/null; then
        local version_output
        version_output=$(snell-server --v 2>&1)
        if echo "$version_output" | grep -q "v5"; then
            echo "v5"
        else
            echo "v4"
        fi
    else
        echo "unknown"
    fi
}

get_current_snell_version() {
    local current_installed_version
    current_installed_version=$(detect_installed_snell_version)

    if [ "$current_installed_version" = "v5" ]; then
        CURRENT_VERSION=$(snell-server --v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*')
        if [ -z "$CURRENT_VERSION" ]; then
            echo -e "${YELLOW}警告：无法读取 v5 详细版本号${RESET}"
            CURRENT_VERSION="v5.0.0b1"  # 仅用于比较的兜底显示（不用于安装）
        fi
    elif [ "$current_installed_version" = "v4" ]; then
        CURRENT_VERSION=$(snell-server --v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')
        if [ -z "$CURRENT_VERSION" ]; then
            echo -e "${RED}无法获取当前 Snell 版本。${RESET}"
            return 1
        fi
    else
        CURRENT_VERSION="unknown"
    fi
}

# 比较版本号（支持 beta：bN 会被当作 .999N 进行比较）
version_greater_equal() {
    local ver1=$1
    local ver2=$2

    ver1=$(echo "${ver1#[vV]}" | tr '[:upper:]' '[:lower:]')
    ver2=$(echo "${ver2#[vV]}" | tr '[:upper:]' '[:lower:]')

    ver1=$(echo "$ver1" | sed 's/b\([0-9]*\)/\.999\1/g')
    ver2=$(echo "$ver2" | sed 's/b\([0-9]*\)/\.999\1/g')

    IFS='.' read -ra VER1 <<< "$ver1"
    IFS='.' read -ra VER2 <<< "$ver2"

    while [ ${#VER1[@]} -lt 4 ]; do VER1+=("0"); done
    while [ ${#VER2[@]} -lt 4 ]; do VER2+=("0"); done

    for i in {0..3}; do
        local val1=${VER1[i]:-0}
        local val2=${VER2[i]:-0}
        if [[ "$val1" =~ ^[0-9]+$ ]] && [[ "$val2" =~ ^[0-9]+$ ]]; then
            if [ "$val1" -gt "$val2" ]; then return 0; elif [ "$val1" -lt "$val2" ]; then return 1; fi
        else
            if [[ "$val1" > "$val2" ]]; then return 0; elif [[ "$val1" < "$val2" ]]; then return 1; fi
        fi
    done
    return 0
}

# ========================= 配置备份/恢复 =========================
backup_snell_config() {
    local backup_dir="/etc/snell/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a /etc/snell/users/*.conf "$backup_dir"/ 2>/dev/null
    echo "$backup_dir"
}

restore_snell_config() {
    local backup_dir="$1"
    if [ -d "$backup_dir" ]; then
        cp -a "$backup_dir"/*.conf /etc/snell/users/
        echo -e "${GREEN}配置已从备份恢复。${RESET}"
    else
        echo -e "${RED}未找到备份目录，无法恢复配置。${RESET}"
    fi
}

# ========================= 端口与防火墙 =========================
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

open_port() {
    local PORT=$1
    if command -v ufw &> /dev/null; then
        echo -e "${CYAN}在 UFW 中开放端口 $PORT${RESET}"
        ufw allow "$PORT"/tcp
        ufw allow "$PORT"/udp
    fi

    if command -v iptables &> /dev/null; then
        echo -e "${CYAN}在 iptables 中开放端口 $PORT${RESET}"
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
        [ ! -d "/etc/iptables" ] && mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 || true
    fi
}

# ========================= 旧配置迁移 =========================
check_and_migrate_config() {
    local need_migration=false
    local old_files_exist=false

    if [ -f "$OLD_SNELL_CONF_FILE" ] || [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
        old_files_exist=true
        echo -e "\n${YELLOW}检测到旧版本的 Snell 配置文件${RESET}"
        echo -e "旧配置位置："
        [ -f "$OLD_SNELL_CONF_FILE" ] && echo -e "- 配置文件：${OLD_SNELL_CONF_FILE}"
        [ -f "$OLD_SYSTEMD_SERVICE_FILE" ] && echo -e "- 服务文件：${OLD_SYSTEMD_SERVICE_FILE}"

        if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
            need_migration=true
            mkdir -p "${SNELL_CONF_DIR}/users"
            chown -R nobody:nogroup "${SNELL_CONF_DIR}"
            chmod -R 755 "${SNELL_CONF_DIR}"
        fi
    fi

    if [ "$old_files_exist" = true ]; then
        echo -e "\n${YELLOW}是否要迁移旧的配置文件？[y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            echo -e "${CYAN}开始迁移配置文件...${RESET}"
            systemctl stop snell 2>/dev/null

            if [ -f "$OLD_SNELL_CONF_FILE" ]; then
                cp "$OLD_SNELL_CONF_FILE" "${SNELL_CONF_FILE}"
                chown nobody:nogroup "${SNELL_CONF_FILE}"
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
            systemctl start snell

            if systemctl is-active --quiet snell; then
                echo -e "${GREEN}配置迁移完成，服务已成功启动${RESET}"
            else
                echo -e "${RED}警告：服务启动失败，请检查配置文件和权限${RESET}"
                systemctl status snell
            fi
        else
            echo -e "${YELLOW}跳过配置迁移${RESET}"
        fi
    fi
}

# ========================= 安装 =========================
install_snell() {
    echo -e "${CYAN}正在安装 Snell${RESET}"

    wait_for_apt
    apt update && apt install -y wget unzip

    SNELL_VERSION=$(get_latest_snell_version) || { echo -e "${RED}未能获取 Snell 最新版本，安装终止${RESET}"; exit 1; }
    SNELL_URL=$(get_snell_download_url "$SNELL_VERSION") || { echo -e "${RED}无法生成下载链接${RESET}"; exit 1; }

    echo -e "${CYAN}正在下载 Snell ${SNELL_VERSION}...${RESET}"
    echo -e "${YELLOW}下载链接: ${SNELL_URL}${RESET}"

    wget -O snell-server.zip "$SNELL_URL" || { echo -e "${RED}下载失败${RESET}"; exit 1; }
    unzip -o snell-server.zip -d ${INSTALL_DIR} || { echo -e "${RED}解压失败${RESET}"; exit 1; }
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
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || { echo -e "${RED}systemd 重载失败${RESET}"; exit 1; }
    systemctl enable snell || { echo -e "${RED}设置开机自启失败${RESET}"; exit 1; }
    systemctl start snell || { echo -e "${RED}启动 Snell 失败${RESET}"; exit 1; }

    open_port "$PORT"

    echo -e "\n${GREEN}安装完成！以下是您的配置信息：${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${YELLOW}版本: ${SNELL_VERSION}${RESET}"
    echo -e "${YELLOW}监听端口: ${PORT}${RESET}"
    echo -e "${YELLOW}PSK 密钥: ${PSK}${RESET}"
    echo -e "${YELLOW}IPv6: true${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"

    # 输出 Surge 配置
    local installed_version
    installed_version=$(detect_installed_snell_version)

    IPV4_ADDR=$(curl -s4 https://api.ipify.org)
    if [ -n "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(curl -s http://ipinfo.io/${IPV4_ADDR}/country)
        echo -e "\n${GREEN}Surge 配置（IPv4）：${RESET}"
        generate_surge_config "$IPV4_ADDR" "$PORT" "$PSK" "$IP_COUNTRY_IPV4" "$installed_version"
    fi

    IPV6_ADDR=$(curl -s6 https://api64.ipify.org)
    if [ -n "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(curl -s https://ipapi.co/${IPV6_ADDR}/country/)
        echo -e "\n${GREEN}Surge 配置（IPv6）：${RESET}"
        generate_surge_config "$IPV6_ADDR" "$PORT" "$PSK" "$IP_COUNTRY_IPV6" "$installed_version"
    fi

    # 安装管理入口命令
    echo -e "${CYAN}正在安装管理脚本入口（/usr/local/bin/snell）...${RESET}"
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/snell << 'EOFSCRIPT'
#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请以 root 权限运行此脚本${RESET}"; exit 1
fi
echo -e "${CYAN}正在获取最新版本的管理脚本...${RESET}"
TMP_SCRIPT=$(mktemp)
if curl -sL https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/snell.sh -o "$TMP_SCRIPT"; then
    bash "$TMP_SCRIPT"; rm -f "$TMP_SCRIPT"
else
    echo -e "${RED}下载脚本失败，请检查网络连接。${RESET}"
    rm -f "$TMP_SCRIPT"; exit 1
fi
EOFSCRIPT
    chmod +x /usr/local/bin/snell || true
    echo -e "${GREEN}管理脚本入口安装完成：${RESET}${YELLOW}snell${RESET}"
}

# ========================= 生成 Surge 配置 =========================
generate_surge_config() {
    local ip_addr=$1
    local port=$2
    local psk=$3
    local country=$4
    local installed_version=$5

    if [ "$installed_version" = "v5" ]; then
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true${RESET}"
    else
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
    fi
}

# ========================= 卸载 =========================
uninstall_snell() {
    echo -e "${CYAN}正在卸载 Snell${RESET}"

    systemctl stop snell 2>/dev/null
    systemctl disable snell 2>/dev/null

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                local port
                port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                if [ -n "$port" ]; then
                    echo -e "${YELLOW}停止并禁用多用户服务 (端口: $port)${RESET}"
                    systemctl stop "snell-${port}" 2>/dev/null
                    systemctl disable "snell-${port}" 2>/dev/null
                    rm -f "${SYSTEMD_DIR}/snell-${port}.service"
                fi
            fi
        done
    fi

    rm -f ${SYSTEMD_SERVICE_FILE}
    rm -f ${INSTALL_DIR}/snell-server
    rm -rf ${SNELL_CONF_DIR}
    rm -f /usr/local/bin/snell

    systemctl daemon-reload
    echo -e "${GREEN}Snell 及其所有多用户配置已成功卸载${RESET}"
}

# ========================= 重启 =========================
restart_snell() {
    echo -e "${YELLOW}正在重启所有 Snell 服务...${RESET}"

    systemctl restart snell
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}主 Snell 服务已成功重启。${RESET}"
    else
        echo -e "${RED}重启主 Snell 服务失败。${RESET}"
    fi

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                local port
                port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                if [ -n "$port" ]; then
                    echo -e "${YELLOW}正在重启用户服务 (端口: $port)${RESET}"
                    systemctl restart "snell-${port}" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}用户服务 (端口: $port) 已成功重启。${RESET}"
                    else
                        echo -e "${RED}重启用户服务 (端口: $port) 失败。${RESET}"
                    fi
                fi
            fi
        done
    fi
}

# ========================= 状态展示 =========================
check_and_show_status() {
    echo -e "\n${CYAN}=============== 服务状态检查 ===============${RESET}"

    if command -v snell-server &> /dev/null; then
        local user_count=0 running_count=0 total_snell_memory=0 total_snell_cpu=0

        if systemctl is-active snell &> /dev/null; then
            user_count=$((user_count + 1))
            running_count=$((running_count + 1))
            local main_pid mem cpu
            main_pid=$(systemctl show -p MainPID snell | cut -d'=' -f2)
            if [ -n "$main_pid" ] && [ "$main_pid" != "0" ]; then
                mem=$(ps -o rss= -p $main_pid 2>/dev/null)
                cpu=$(ps -o %cpu= -p $main_pid 2>/dev/null)
                [ -n "$mem" ] && total_snell_memory=$((total_snell_memory + mem))
                [ -n "$cpu" ] && total_snell_cpu=$(echo "$total_snell_cpu + $cpu" | bc -l)
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
                            if [ -n "$user_pid" ] && [ "$user_pid" != "0" ]; then
                                mem=$(ps -o rss= -p $user_pid 2>/dev/null)
                                cpu=$(ps -o %cpu= -p $user_pid 2>/dev/null)
                                [ -n "$mem" ] && total_snell_memory=$((total_snell_memory + mem))
                                [ -n "$cpu" ] && total_snell_cpu=$(echo "$total_snell_cpu + $cpu" | bc -l)
                            fi
                        fi
                    fi
                fi
            done
        fi

        local total_snell_memory_mb
        total_snell_memory_mb=$(echo "scale=2; $total_snell_memory/1024" | bc)
        printf "${GREEN}Snell 已安装${RESET}  ${YELLOW}CPU：%.2f%%${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${running_count}/${user_count}${RESET}\n" "$total_snell_cpu" "$total_snell_memory_mb"
    else
        echo -e "${YELLOW}Snell 未安装${RESET}"
    fi

    if [ -f "/usr/local/bin/shadow-tls" ]; then
        local stls_total=0 stls_running=0 total_stls_memory=0 total_stls_cpu=0
        declare -A processed_ports
        local snell_services
        snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
        if [ -n "$snell_services" ]; then
            while IFS= read -r service_file; do
                local port
                port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
                if [ -z "${processed_ports[$port]}" ]; then
                    processed_ports[$port]=1
                    stls_total=$((stls_total + 1))
                    if systemctl is-active "shadowtls-snell-${port}" &> /dev/null; then
                        stls_running=$((stls_running + 1))
                        local stls_pid mem cpu
                        stls_pid=$(systemctl show -p MainPID "shadowtls-snell-${port}" | cut -d'=' -f2)
                        if [ -n "$stls_pid" ] && [ "$stls_pid" != "0" ]; then
                            mem=$(ps -o rss= -p $stls_pid 2>/dev/null)
                            cpu=$(ps -o %cpu= -p $stls_pid 2>/dev/null)
                            [ -n "$mem" ] && total_stls_memory=$((total_stls_memory + mem))
                            [ -n "$cpu" ] && total_stls_cpu=$(echo "$total_stls_cpu + $cpu" | bc -l)
                        fi
                    fi
                fi
            done <<< "$snell_services"
        fi

        if [ $stls_total -gt 0 ]; then
            local total_stls_memory_mb
            total_stls_memory_mb=$(echo "scale=2; $total_stls_memory/1024" | bc)
            printf "${GREEN}ShadowTLS 已安装${RESET}  ${YELLOW}CPU：%.2f%%${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${stls_running}/${stls_total}${RESET}\n" "$total_stls_cpu" "$total_stls_memory_mb"
        else
            echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
        fi
    else
        echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
    fi

    echo -e "${CYAN}============================================${RESET}\n"
}

# ========================= 配置查看（含 ShadowTLS 组合配置） =========================
get_snell_port() {
    if [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ]; then
        grep -E '^listen' "${SNELL_CONF_DIR}/users/snell-main.conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p'
    fi
}

view_snell_config() {
    echo -e "${GREEN}Snell 配置信息:${RESET}"
    echo -e "${CYAN}================================${RESET}"

    local installed_version
    installed_version=$(detect_installed_snell_version)
    if [ "$installed_version" != "unknown" ]; then
        echo -e "${YELLOW}当前安装版本: Snell ${installed_version}${RESET}"
    fi

    IPV4_ADDR=$(curl -s4 https://api.ipify.org)
    if [ -n "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(curl -s http://ipinfo.io/${IPV4_ADDR}/country)
        echo -e "${GREEN}IPv4 地址: ${RESET}${IPV4_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV4}"
    fi

    IPV6_ADDR=$(curl -s6 https://api64.ipify.org)
    if [ -n "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(curl -s https://ipapi.co/${IPV6_ADDR}/country/)
        echo -e "${GREEN}IPv6 地址: ${RESET}${IPV6_ADDR} ${GREEN}所在国家: ${RESET}${IP_COUNTRY_IPV6}"
    fi

    if [ -z "$IPV4_ADDR" ] && [ -z "$IPV6_ADDR" ]; then
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
        if [ -n "$IPV4_ADDR" ]; then
            generate_surge_config "$IPV4_ADDR" "$main_port" "$main_psk" "$IP_COUNTRY_IPV4" "$installed_version"
        fi
        if [ -n "$IPV6_ADDR" ]; then
            generate_surge_config "$IPV6_ADDR" "$main_port" "$main_psk" "$IP_COUNTRY_IPV6" "$installed_version"
        fi
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
                if [ -n "$IPV4_ADDR" ]; then
                    generate_surge_config "$IPV4_ADDR" "$user_port" "$user_psk" "$IP_COUNTRY_IPV4" "$installed_version"
                fi
                if [ -n "$IPV6_ADDR" ]; then
                    generate_surge_config "$IPV6_ADDR" "$user_port" "$user_psk" "$IP_COUNTRY_IPV6" "$installed_version"
                fi
            fi
        done
    fi

    # ShadowTLS 组合配置
    local snell_version
    snell_version=$(detect_installed_snell_version)
    local snell_services
    snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
    if [ -n "$snell_services" ]; then
        echo -e "\n${YELLOW}=== ShadowTLS 组合配置 ===${RESET}"
        declare -A processed_ports
        while IFS= read -r service_file; do
            local exec_line stls_port stls_password stls_domain snell_port
            exec_line=$(grep "ExecStart=" "$service_file")
            stls_port=$(echo "$exec_line" | grep -oP '(?<=--listen ::0:)\d+')
            stls_password=$(echo "$exec_line" | grep -oP '(?<=--password )[^ ]+')
            stls_domain=$(echo "$exec_line" | grep -oP '(?<=--tls )[^ ]+')
            snell_port=$(echo "$exec_line" | grep -oP '(?<=--server 127.0.0.1:)\d+')

            local psk=""
            if [ -f "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" ]; then
                psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" | awk -F'=' '{print $2}' | tr -d ' ')
            elif [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ] && [ "$snell_port" = "$(get_snell_port)" ]; then
                psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-main.conf" | awk -F'=' '{print $2}' | tr -d ' ')
            fi

            if [ -z "$snell_port" ] || [ -z "$psk" ] || [ -n "${processed_ports[$snell_port]}" ]; then
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

            if [ -n "$IPV4_ADDR" ]; then
                if [ "$snell_version" = "v5" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                else
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                fi
            fi
            if [ -n "$IPV6_ADDR" ]; then
                if [ "$snell_version" = "v5" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                else
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                fi
            fi
        done <<< "$snell_services"
    fi

    echo -e "\n${YELLOW}注意：${RESET}"
    echo -e "1. Snell 仅支持 Surge 客户端"
    echo -e "2. 请将配置中的服务器地址替换为实际可用的地址"
    read -p "按任意键返回主菜单..."
}

# ========================= 只更新二进制（保留配置） =========================
update_snell_binary() {
    echo -e "${CYAN}=============== Snell 更新 ===============${RESET}"
    echo -e "${YELLOW}注意：这是更新操作，不是重新安装${RESET}"
    echo -e "${GREEN}✓ 所有现有配置将被保留${RESET}"
    echo -e "${GREEN}✓ 端口、密码、用户配置都不会改变${RESET}"
    echo -e "${GREEN}✓ 服务会自动重启${RESET}"
    echo -e "${CYAN}============================================${RESET}"

    echo -e "${CYAN}正在备份当前配置...${RESET}"
    local backup_dir
    backup_dir=$(backup_snell_config)
    echo -e "${GREEN}配置已备份到: $backup_dir${RESET}"

    # 若外部未设置 SNELL_VERSION，则此处再拉一次
    if [ -z "$SNELL_VERSION" ]; then
        SNELL_VERSION=$(get_latest_snell_version) || { echo -e "${RED}获取最新版本失败${RESET}"; restore_snell_config "$backup_dir"; return 1; }
    fi
    local SNELL_URL
    SNELL_URL=$(get_snell_download_url "$SNELL_VERSION") || { echo -e "${RED}拼接下载链接失败${RESET}"; restore_snell_config "$backup_dir"; return 1; }

    echo -e "${CYAN}正在下载 Snell ${SNELL_VERSION}...${RESET}"
    wget -O snell-server.zip "$SNELL_URL" || { echo -e "${RED}下载失败${RESET}"; restore_snell_config "$backup_dir"; return 1; }

    echo -e "${CYAN}正在替换 Snell 二进制文件...${RESET}"
    unzip -o snell-server.zip -d ${INSTALL_DIR} || { echo -e "${RED}解压缩失败${RESET}"; restore_snell_config "$backup_dir"; rm -f snell-server.zip; return 1; }
    rm -f snell-server.zip
    chmod +x ${INSTALL_DIR}/snell-server

    echo -e "${CYAN}正在重启 Snell 服务...${RESET}"
    systemctl restart snell || { echo -e "${RED}主服务重启失败${RESET}"; }

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                local port
                port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                [ -n "$port" ] && systemctl restart "snell-${port}" 2>/dev/null
            fi
        done
    fi

    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}✅ Snell 更新完成！${RESET}"
    echo -e "${GREEN}✓ 版本已更新到: ${SNELL_VERSION}${RESET}"
    echo -e "${GREEN}✓ 所有配置已保留${RESET}"
    echo -e "${GREEN}✓ 服务已重启${RESET}"
    echo -e "${YELLOW}配置备份目录: $backup_dir${RESET}"
    echo -e "${CYAN}============================================${RESET}"
}

# ========================= 检查更新 =========================
check_snell_update() {
    echo -e "\n${CYAN}=============== 检查 Snell 更新 ===============${RESET}"

    local current_installed_version
    current_installed_version=$(detect_installed_snell_version)
    if [ "$current_installed_version" = "unknown" ]; then
        echo -e "${RED}无法检测当前 Snell 版本${RESET}"
        return 1
    fi
    echo -e "${YELLOW}当前安装大版本: ${current_installed_version}${RESET}"

    get_current_snell_version || return 1
    SNELL_VERSION=$(get_latest_snell_version) || { echo -e "${RED}获取最新版本失败${RESET}"; return 1; }

    echo -e "${YELLOW}当前 Snell 版本: ${CURRENT_VERSION}${RESET}"
    echo -e "${YELLOW}最新 Snell 版本: ${SNELL_VERSION}${RESET}"

    if ! version_greater_equal "$CURRENT_VERSION" "$SNELL_VERSION"; then
        echo -e "\n${CYAN}发现新版本，更新说明：${RESET}"
        echo -e "${GREEN}✓ 这是更新操作，不是重新安装${RESET}"
        echo -e "${GREEN}✓ 所有现有配置将被保留（端口、密码、用户配置）${RESET}"
        echo -e "${GREEN}✓ 服务会自动重启${RESET}"
        echo -e "${GREEN}✓ 配置文件会自动备份${RESET}"
        echo -e "${CYAN}是否更新 Snell? [y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            update_snell_binary
        else
            echo -e "${CYAN}已取消更新。${RESET}"
        fi
    else
        echo -e "${GREEN}当前已是最新版本（${CURRENT_VERSION}）。${RESET}"
    fi
}

# ========================= 其它功能（脚本更新/多用户/BBR/ShadowTLS） =========================
auto_update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"
    TMP_SCRIPT=$(mktemp)
    if curl -sL https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/snell.sh -o "$TMP_SCRIPT"; then
        new_version=$(grep "current_version=" "$TMP_SCRIPT" | cut -d'"' -f2)
        if [ "$new_version" != "$current_version" ] && [ -n "$new_version" ]; then
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

get_latest_github_version() {
    local api_url="https://api.github.com/repos/sealszzz/Rules/Surge/snell.sh/releases/latest"
    local response
    response=$(curl -s "$api_url")
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        echo -e "${RED}无法获取 GitHub 上的最新版本信息。${RESET}"
        return 1
    fi
    GITHUB_VERSION=$(echo "$response" | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    if [ -z "$GITHUB_VERSION" ]; then
        echo -e "${RED}解析 GitHub 版本信息失败。${RESET}"
        return 1
    fi
}

update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"
    TMP_SCRIPT=$(mktemp)
    if curl -sL https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/snell.sh -o "$TMP_SCRIPT"; then
        new_version=$(grep "current_version=" "$TMP_SCRIPT" | cut -d'"' -f2)
        if [ -z "$new_version" ]; then
            echo -e "${RED}无法获取新版本信息${RESET}"
            rm -f "$TMP_SCRIPT"; return 1
        fi
        echo -e "${YELLOW}当前版本：${current_version}${RESET}"
        echo -e "${YELLOW}最新版本：${new_version}${RESET}"

        if [ "$new_version" = "$current_version" ]; then
            echo -e "${GREEN}当前已是最新版本 (${current_version})，跳过更新。${RESET}"
            rm -f "$TMP_SCRIPT"; return 0
        fi

        echo -e "${CYAN}发现新版本，是否更新到新版本？[y/N]${RESET}"
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
            rm -f "$TMP_SCRIPT"; return 0
        fi
    else
        echo -e "${RED}下载新版本失败，请检查网络连接${RESET}"
        rm -f "$TMP_SCRIPT"; return 1
    fi
}

check_installation() {
    local service=$1
    if systemctl list-unit-files | grep -q "^$service.service"; then
        echo -e "${GREEN}已安装${RESET}"
    else
        echo -e "${RED}未安装${RESET}"
    fi
}

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

get_shadowtls_config() {
    local main_port service_name service_file exec_line tls_domain password listen_part listen_port
    main_port=$(get_snell_port)
    [ -z "$main_port" ] && return 1

    service_name="shadowtls-snell-${main_port}"
    systemctl is-active --quiet "$service_name" || return 1

    service_file="/etc/systemd/system/${service_name}.service"
    [ ! -f "$service_file" ] && return 1

    exec_line=$(grep "ExecStart=" "$service_file") || return 1
    tls_domain=$(echo "$exec_line" | grep -o -- "--tls [^ ]*" | cut -d' ' -f2)
    password=$(echo "$exec_line" | grep -o -- "--password [^ ]*" | cut -d' ' -f2)
    listen_part=$(echo "$exec_line" | grep -o -- "--listen [^ ]*" | cut -d' ' -f2)
    listen_port=$(echo "$listen_part" | grep -o '[0-9]*$')

    if [ -z "$tls_domain" ] || [ -z "$password" ] || [ -z "$listen_port" ]; then
        return 1
    fi

    echo "${password}|${tls_domain}|${listen_port}"
    return 0
}

# ========================= 初始检查与菜单 =========================
initial_check() {
    check_root
    check_curl
    check_bc
    check_and_migrate_config
    check_and_show_status
}

show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}           Snell 管理脚本 v${current_version} ${RESET}"
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
    echo -e "${GREEN}8.${RESET} 更新 Snell（检查并升级）"
    echo -e "${GREEN}9.${RESET} 更新脚本"
    echo -e "${GREEN}10.${RESET} 查看服务状态"
    echo -e "${GREEN}0.${RESET} 退出脚本"

    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项 [0-10]: " num
}

# ========================= 入口 =========================
initial_check

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
