#!/usr/bin/env bash
set -euo pipefail

############################################
#              全局与样式                  #
############################################
SCRIPT_VERSION="2025.10.05-allin1"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'
INFO="${GREEN}[信息]${PLAIN}"; WARN="${YELLOW}[注意]${PLAIN}"; ERR="${RED}[错误]${PLAIN}"; OK="${GREEN}[成功]${PLAIN}"

# 目录/路径（统一）
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

# Snell
SNELL_CONF_DIR="/etc/snell"
SNELL_USERS_DIR="${SNELL_CONF_DIR}/users"
SNELL_MAIN_CONF="${SNELL_USERS_DIR}/snell-main.conf"
SNELL_SERVICE="${SYSTEMD_DIR}/snell.service"
SNELL_BIN="${INSTALL_DIR}/snell-server"
OLD_SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
OLD_SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"

# SS-Rust
SSR_INSTALL_DIR="/etc/ss-rust"
SSR_BIN="${INSTALL_DIR}/ss-rust"
SSR_CONFIG="${SSR_INSTALL_DIR}/config.json"
SSR_VERSION_FILE="${SSR_INSTALL_DIR}/ver.txt"

# ShadowTLS
STLS_BIN="${INSTALL_DIR}/shadow-tls"

# 统一退出
error_exit(){ echo -e "${ERR} $*"; exit 1; }

# Root & APT 锁
check_root(){ [[ $EUID -eq 0 ]] || error_exit "请使用 root 权限运行"; }
wait_for_apt(){ while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do echo -e "${YELLOW}等待其它 apt 进程…${PLAIN}"; sleep 1; done; }

# 依赖安装（按需）
need_tools=(curl jq wget unzip xz-utils tar qrencode bc iproute2 net-tools)
ensure_tools(){
  local missing=()
  for t in "$@"; do command -v "$t" &>/dev/null || missing+=("$t"); done
  if ((${#missing[@]})); then
    if command -v apt &>/dev/null; then
      wait_for_apt; apt update; apt install -y "${missing[@]}"
    elif command -v yum &>/dev/null; then
      yum install -y "${missing[@]}"
    else
      error_exit "不支持的包管理器，缺少依赖：${missing[*]}"
    fi
  fi
}
ensure_base(){ ensure_tools "${need_tools[@]}"; }

# 端口/防火墙
rand_port(){ shuf -i 30000-39999 -n 1; }
port_in_use(){
  local p="$1"
  if command -v ss &>/dev/null; then ss -lntup | grep -qE "[:.]${p}\s"; return $?; fi
  if command -v netstat &>/dev/null; then netstat -tuln | grep -q ":${p}\b"; return $?; fi
  return 1
}
fw_open(){
  local p="$1"
  if command -v ufw &>/dev/null; then ufw allow "${p}"/tcp || true; ufw allow "${p}"/udp || true; fi
  if command -v iptables &>/dev/null; then
    iptables -I INPUT -p tcp --dport "$p" -j ACCEPT || true
    iptables -I INPUT -p udp --dport "$p" -j ACCEPT || true
    mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
}

# IP 获取
get_ipv4(){ curl -s4 --max-time 3 https://api.ipify.org || true; }
get_ipv6(){ curl -s6 --max-time 3 https://api64.ipify.org || true; }

# Base64（URL safe，无 padding）
urlsafe_b64(){ printf "%s" "$1" | base64 | tr -d '=' | tr '+/' '-_'; }

# 随机字符串
rand_str(){ tr -dc A-Za-z0-9 </dev/urandom | head -c "${1:-16}"; }

# 架构识别（给 release 选择）
detect_arch_ssrust(){
  local arch=$(uname -m); local os=$(uname -s)
  if [[ "$os" == "Linux" ]]; then
    case "$arch" in
      x86_64) echo "x86_64-unknown-linux-gnu" ;;
      aarch64) echo "aarch64-unknown-linux-gnu" ;;
      armv7l|armv7) echo "armv7-unknown-linux-gnueabihf" ;;
      armv6l) echo "arm-unknown-linux-gnueabi" ;;
      i686|i386) echo "i686-unknown-linux-musl" ;;
      *) error_exit "不支持的 CPU 架构: $arch" ;;
    esac
  else
    error_exit "不支持的 OS：$os"
  fi
}

############################################
#                 Snell                    #
############################################

snell_get_latest_version(){
  # 抓 KB：优先 beta（X.Y.ZbN），否则稳定
  local url="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"
  local html v_beta v_stable
  html=$(curl -fsSL --connect-timeout 5 -m 10 "$url") || return 1

  v_beta=$(printf '%s' "$html" \
    | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+b[0-9]+' \
    | sed -E 's/^snell-server-v//' \
    | sed -E 's/b([0-9]+)/-beta.\1/' \
    | sort -V | tail -n1 \
    | sed -E 's/-beta\.([0-9]+)/b\1/')

  if [[ -n "$v_beta" ]]; then echo "v${v_beta}"; return 0; fi

  v_stable=$(printf '%s' "$html" \
    | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+' \
    | sed -E 's/^snell-server-v//' \
    | sort -V | tail -n1)
  [[ -n "$v_stable" ]] && { echo "v${v_stable}"; return 0; }

  return 1
}

snell_dl_url(){
  local ver="$1" arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)   echo "https://dl.nssurge.com/snell/snell-server-${ver}-linux-amd64.zip" ;;
    i386|i686)      echo "https://dl.nssurge.com/snell/snell-server-${ver}-linux-i386.zip" ;;
    aarch64|arm64)  echo "https://dl.nssurge.com/snell/snell-server-${ver}-linux-aarch64.zip" ;;
    armv7l|armv7)   echo "https://dl.nssurge.com/snell/snell-server-${ver}-linux-armv7l.zip" ;;
    *) error_exit "不支持的架构: $arch" ;;
  esac
}

snell_detect_installed_major(){
  if command -v "$SNELL_BIN" &>/dev/null; then
    local out=$("$SNELL_BIN" --v 2>&1 | tr -d '\r')
    local major=$(echo "$out" | grep -oP 'v[0-9]+' | head -n1)
    [[ -n "$major" ]] && echo "$major" || echo "unknown"
  else
    echo "unknown"
  fi
}

snell_current_full_version(){
  "$SNELL_BIN" --v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*'
}

snell_ver_ge(){ # beta bN 视作 .999N
  local a="${1#v}"; local b="${2#v}"
  a=$(echo "$a" | sed 's/b\([0-9]\+\)/.999\1/g')
  b=$(echo "$b" | sed 's/b\([0-9]\+\)/.999\1/g')
  IFS='.' read -r -a A <<< "$a"; IFS='.' read -r -a B <<< "$b"
  while ((${#A[@]}<4)); do A+=("0"); done
  while ((${#B[@]}<4)); do B+=("0"); done
  for i in 0 1 2 3; do
    [[ "${A[i]}" -gt "${B[i]}" ]] && return 0
    [[ "${A[i]}" -lt "${B[i]}" ]] && return 1
  done
  return 0
}

snell_backup_cfg(){ local b="/etc/snell/backup_$(date +%Y%m%d_%H%M%S)"; mkdir -p "$b"; cp -a "${SNELL_USERS_DIR}"/*.conf "$b"/ 2>/dev/null || true; echo "$b"; }

snell_migrate_old(){
  local changed=false
  if [[ -f "$OLD_SNELL_CONF_FILE" || -f "$OLD_SYSTEMD_SERVICE_FILE" ]]; then
    echo -e "${YELLOW}检测到旧版路径，尝试迁移…${PLAIN}"
    mkdir -p "$SNELL_USERS_DIR"
    chown -R nobody:nogroup "$SNELL_CONF_DIR" 2>/dev/null || true
    chmod -R 755 "$SNELL_CONF_DIR" 2>/dev/null || true
    if [[ -f "$OLD_SNELL_CONF_FILE" ]]; then
      cp "$OLD_SNELL_CONF_FILE" "$SNELL_MAIN_CONF"; changed=true
    fi
    if [[ -f "$OLD_SYSTEMD_SERVICE_FILE" ]]; then
      sed -e "s|$OLD_SNELL_CONF_FILE|$SNELL_MAIN_CONF|g" "$OLD_SYSTEMD_SERVICE_FILE" > "$SNELL_SERVICE"; changed=true
    fi
    if $changed; then
      systemctl daemon-reload
      systemctl try-restart snell 2>/dev/null || true
      echo -e "${OK} 旧配置迁移完成"
    fi
  fi
}

snell_install(){
  ensure_base
  wait_for_apt
  command -v unzip &>/dev/null || { apt update; apt install -y unzip; }
  mkdir -p "$SNELL_USERS_DIR"

  local ver url
  ver=$(snell_get_latest_version) || error_exit "无法获取 Snell 最新版本"
  url=$(snell_dl_url "$ver")

  echo -e "${INFO} 下载 Snell ${ver}\n${YELLOW}${url}${PLAIN}"
  wget -O /tmp/snell.zip "$url" || error_exit "下载失败"
  unzip -o /tmp/snell.zip -d "$INSTALL_DIR" || error_exit "解压失败"
  rm -f /tmp/snell.zip
  chmod +x "$SNELL_BIN"

  # 主端口
  local PORT
  read -rp "请输入 Snell 监听端口 (回车随机 30000-39999): " PORT || true
  if [[ -z "${PORT:-}" ]]; then
    PORT=$(rand_port)
  else
    [[ "$PORT" =~ ^[0-9]+$ && $PORT -ge 1 && $PORT -le 65535 ]] || error_exit "端口非法"
  fi
  fw_open "$PORT"
  local PSK; PSK=$(rand_str 20)

  cat >"$SNELL_MAIN_CONF"<<EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = true
EOF

  cat >"$SNELL_SERVICE"<<EOF
[Unit]
Description=Snell Proxy Service (Main)
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=${SNELL_BIN} -c ${SNELL_MAIN_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable snell
  systemctl start snell || { journalctl -u snell --no-pager | tail -n 50; error_exit "Snell 启动失败"; }

  snell_migrate_old

  # 输出信息
  local ipv4 ipv6 c4 c6 maj
  ipv4=$(get_ipv4); [[ -n "$ipv4" ]] && c4=$(curl -s "http://ipinfo.io/${ipv4}/country" || true)
  ipv6=$(get_ipv6); [[ -n "$ipv6" ]] && c6=$(curl -s "https://ipapi.co/${ipv6}/country/" || true)
  maj=$(snell_detect_installed_major)

  echo -e "\n${OK} Snell 安装完成"
  echo -e "${YELLOW}版本: ${ver}${PLAIN}\n${YELLOW}端口: ${PORT}${PLAIN}\n${YELLOW}PSK : ${PSK}${PLAIN}"
  if [[ -n "$ipv4" ]]; then
    echo -e "\n${GREEN}Surge（IPv4）：${PLAIN}"
    echo -e "${c4:-IPV4} = snell, ${ipv4}, ${PORT}, psk = ${PSK}, version = ${maj#v}, reuse = true, tfo = true"
  fi
  if [[ -n "$ipv6" ]]; then
    echo -e "\n${GREEN}Surge（IPv6）：${PLAIN}"
    echo -e "${c6:-IPV6} = snell, ${ipv6}, ${PORT}, psk = ${PSK}, version = ${maj#v}, reuse = true, tfo = true"
  fi
}

snell_uninstall(){
  systemctl stop snell 2>/dev/null || true
  systemctl disable snell 2>/dev/null || true

  # 停掉多用户
  if [[ -d "$SNELL_USERS_DIR" ]]; then
    for f in "$SNELL_USERS_DIR"/*; do
      [[ -f "$f" ]] || continue
      local port; port=$(grep -E '^listen' "$f" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
      [[ -n "$port" ]] || continue
      systemctl stop "snell-${port}" 2>/dev/null || true
      systemctl disable "snell-${port}" 2>/dev/null || true
      rm -f "${SYSTEMD_DIR}/snell-${port}.service"
    done
  fi

  rm -f "$SNELL_SERVICE" "$SNELL_BIN"
  rm -rf "$SNELL_CONF_DIR"
  systemctl daemon-reload
  echo -e "${OK} Snell 及多用户已卸载"
}

snell_restart(){
  systemctl restart snell || error_exit "重启失败"
  echo -e "${OK} 已重启 snell"
}

snell_status(){
  systemctl status snell --no-pager || true
  echo
  echo -e "${YELLOW}进程摘要：${PLAIN}"
  systemctl is-active snell &>/dev/null && echo -e "主服务：${GREEN}运行中${PLAIN}" || echo -e "主服务：${RED}未运行${PLAIN}"
  if [[ -d "$SNELL_USERS_DIR" ]]; then
    for f in "$SNELL_USERS_DIR"/*; do
      [[ -f "$f" && "$f" != "$SNELL_MAIN_CONF" ]] || continue
      local port; port=$(grep -E '^listen' "$f" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
      [[ -n "$port" ]] || continue
      systemctl is-active "snell-${port}" &>/dev/null \
        && echo -e "snell-${port}：${GREEN}运行中${PLAIN}" \
        || echo -e "snell-${port}：${RED}未运行${PLAIN}"
    done
  fi
}

snell_view(){
  local ipv4 ipv6 c4 c6 maj
  maj=$(snell_detect_installed_major)
  echo -e "${INFO} 当前安装大版本：${maj}"
  [[ -f "$SNELL_MAIN_CONF" ]] || { echo -e "${WARN} 未找到 ${SNELL_MAIN_CONF}"; return 0; }

  local port psk ipv6_on
  port=$(grep -E '^listen' "$SNELL_MAIN_CONF" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
  psk=$(grep -E '^psk' "$SNELL_MAIN_CONF" | awk -F'=' '{print $2}' | tr -d ' ')
  ipv6_on=$(grep -E '^ipv6' "$SNELL_MAIN_CONF" | awk -F'=' '{print $2}' | tr -d ' ')
  echo -e "\n${GREEN}主配置：${PLAIN}\n端口：${port}\nPSK ：${psk}\nIPv6：${ipv6_on}"

  ipv4=$(get_ipv4); [[ -n "$ipv4" ]] && c4=$(curl -s "http://ipinfo.io/${ipv4}/country" || true)
  ipv6=$(get_ipv6); [[ -n "$ipv6" ]] && c6=$(curl -s "https://ipapi.co/${ipv6}/country/" || true)

  if [[ -n "$ipv4" ]]; then
    echo -e "\n${GREEN}Surge（IPv4）：${PLAIN}"
    echo -e "${c4:-IPV4} = snell, ${ipv4}, ${port}, psk = ${psk}, version = ${maj#v}, reuse = true, tfo = true"
  fi
  if [[ -n "$ipv6" ]]; then
    echo -e "\n${GREEN}Surge（IPv6）：${PLAIN}"
    echo -e "${c6:-IPV6} = snell, ${ipv6}, ${port}, psk = ${psk}, version = ${maj#v}, reuse = true, tfo = true"
  fi

  # ShadowTLS 组合信息（如存在）
  local services; services=$(find "$SYSTEMD_DIR" -maxdepth 1 -name "shadowtls-snell-*.service" 2>/dev/null | sort -u || true)
  if [[ -n "$services" ]]; then
    echo -e "\n${YELLOW}=== ShadowTLS 组合配置 ===${PLAIN}"
    while IFS= read -r svc; do
      [[ -n "$svc" ]] || continue
      local exec stls_port stls_pwd stls_sni snell_port
      exec=$(grep ExecStart= "$svc")
      stls_port=$(echo "$exec" | grep -oP '(?<=--listen ::0:)\d+')
      stls_pwd=$(echo "$exec" | grep -oP '(?<=--password )\S+')
      stls_sni=$(echo "$exec" | grep -oP '(?<=--tls )\S+')
      snell_port=$(echo "$exec" | grep -oP '(?<=--server 127.0.0.1:)\d+')
      [[ -n "$snell_port" && -n "$stls_port" && -n "$stls_pwd" && -n "$stls_sni" ]] || continue

      local used_psk=""
      if [[ -f "${SNELL_USERS_DIR}/snell-${snell_port}.conf" ]]; then
        used_psk=$(grep -E '^psk' "${SNELL_USERS_DIR}/snell-${snell_port}.conf" | awk -F'=' '{print $2}' | tr -d ' ')
      elif [[ "$snell_port" == "$port" ]]; then
        used_psk="$psk"
      fi

      echo -e "\nSnell 端口：${snell_port}\nPSK：${used_psk}\nShadowTLS 监听：${stls_port}\nSNI：${stls_sni}\n版本：3"
      if [[ -n "$ipv4" ]]; then
        echo -e "${GREEN}Surge：${PLAIN}"
        echo -e "snell, ${ipv4}, ${stls_port}, psk = ${used_psk}, version = ${maj#v}, reuse = true, tfo = true, shadow-tls-password = ${stls_pwd}, shadow-tls-sni = ${stls_sni}, shadow-tls-version = 3"
      fi
      if [[ -n "$ipv6" ]]; then
        echo -e "snell, ${ipv6}, ${stls_port}, psk = ${used_psk}, version = ${maj#v}, reuse = true, tfo = true, shadow-tls-password = ${stls_pwd}, shadow-tls-sni = ${stls_sni}, shadow-tls-version = 3"
      fi
    done <<< "$services"
  fi
}

snell_update_binary(){
  ensure_base
  command -v "$SNELL_BIN" &>/dev/null || error_exit "Snell 未安装"
  local cur latest; cur=$(snell_current_full_version || true); latest=$(snell_get_latest_version) || error_exit "获取最新版本失败"
  echo -e "${INFO} 当前：${cur:-未知}  最新：${latest}"
  if snell_ver_ge "$cur" "$latest"; then
    echo -e "${OK} 已是最新"
    return 0
  fi

  local backup; backup=$(snell_backup_cfg); echo -e "${INFO} 已备份配置到：$backup"
  local url; url=$(snell_dl_url "$latest")
  wget -O /tmp/snell.zip "$url" || { echo -e "${ERR} 下载失败，回滚配置"; return 1; }
  unzip -o /tmp/snell.zip -d "$INSTALL_DIR" || { echo -e "${ERR} 解压失败，回滚"; return 1; }
  rm -f /tmp/snell.zip
  chmod +x "$SNELL_BIN"
  systemctl restart snell || echo -e "${WARN} 主服务重启失败，请手动检查"
  # 重启多用户
  if [[ -d "$SNELL_USERS_DIR" ]]; then
    for f in "$SNELL_USERS_DIR"/*; do
      [[ -f "$f" && "$f" != "$SNELL_MAIN_CONF" ]] || continue
      local port; port=$(grep -E '^listen' "$f" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
      [[ -n "$port" ]] && systemctl restart "snell-${port}" 2>/dev/null || true
    done
  fi
  echo -e "${OK} Snell 已升级到 ${latest}"
}

############################################
#              Snell 多用户                #
############################################
snell_ports_in_use(){ # 列出现有 snell 端口
  [[ -d "$SNELL_USERS_DIR" ]] || return 0
  for f in "$SNELL_USERS_DIR"/snell-*.conf; do
    [[ -f "$f" ]] || continue
    grep -E '^listen' "$f" | sed -n 's/.*::0:\([0-9]*\)/\1/p'
  done | sort -n | uniq
}

snell_port_taken(){
  local p="$1"
  # config 占用
  if [[ -d "$SNELL_USERS_DIR" ]]; then
    for f in "$SNELL_USERS_DIR"/*; do
      [[ -f "$f" ]] || continue
      local u; u=$(grep -E '^listen' "$f" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
      [[ "$u" == "$p" ]] && return 0
    done
  fi
  # 主配置
  if [[ -f "$SNELL_MAIN_CONF" ]]; then
    local m; m=$(grep -E '^listen' "$SNELL_MAIN_CONF" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
    [[ "$m" == "$p" ]] && return 0
  fi
  return 1
}

snell_multi_list(){
  echo -e "\n${YELLOW}=== 当前 Snell 用户 ===${PLAIN}"
  if [[ -d "$SNELL_USERS_DIR" ]]; then
    local cnt=0
    for f in "$SNELL_USERS_DIR"/*; do
      [[ -f "$f" ]] || continue
      cnt=$((cnt+1))
      local port psk
      port=$(grep -E '^listen' "$f" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
      psk=$(grep -E '^psk' "$f" | awk -F'=' '{print $2}' | tr -d ' ')
      echo -e "${GREEN}用户 ${cnt}${PLAIN}\n  端口: ${port}\n  PSK : ${psk}\n  文件: ${f}\n"
    done
    ((cnt==0)) && echo -e "${WARN} 暂无用户"
  else
    echo -e "${WARN} 暂无用户"
  fi
}

snell_multi_add(){
  mkdir -p "$SNELL_USERS_DIR"
  local PORT
  while true; do
    read -rp "请输入新用户端口(1-65535，回车随机): " PORT || true
    if [[ -z "${PORT:-}" ]]; then PORT=$(rand_port); fi
    [[ "$PORT" =~ ^[0-9]+$ && $PORT -ge 1 && $PORT -le 65535 ]] || { echo -e "${ERR} 端口非法"; continue; }
    if snell_port_taken "$PORT"; then echo -e "${ERR} 端口已被 Snell 配置占用"; continue; fi
    port_in_use "$PORT" && { echo -e "${ERR} 端口被系统占用"; continue; }
    break
  done
  local PSK; PSK=$(rand_str 20)
  # DNS（默认系统）
  local DNS
  local sysdns=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd, -)
  read -rp "请输入 DNS（回车使用系统DNS：${sysdns:-1.1.1.1,8.8.8.8}）: " DNS || true
  [[ -z "${DNS:-}" ]] && DNS="${sysdns:-1.1.1.1,8.8.8.8}"

  local user_conf="${SNELL_USERS_DIR}/snell-${PORT}.conf"
  cat >"$user_conf"<<EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = true
dns = ${DNS}
EOF

  cat >"${SYSTEMD_DIR}/snell-${PORT}.service"<<EOF
[Unit]
Description=Snell Proxy Service (Port ${PORT})
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=${SNELL_BIN} -c ${user_conf}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server-${PORT}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "snell-${PORT}"
  systemctl start "snell-${PORT}"
  fw_open "$PORT"

  echo -e "${OK} 已添加：端口 ${PORT}  PSK ${PSK}"
}

snell_multi_del(){
  snell_multi_list
  local p; read -rp "请输入要删除的端口: " p
  local conf="${SNELL_USERS_DIR}/snell-${p}.conf"
  local service="snell-${p}.service"
  [[ -f "$conf" ]] || { echo -e "${ERR} 未找到该端口配置"; return; }
  systemctl stop "snell-${p}" 2>/dev/null || true
  systemctl disable "snell-${p}" 2>/dev/null || true
  rm -f "${SYSTEMD_DIR}/${service}" "/lib/systemd/system/${service}" "$conf"
  systemctl daemon-reload
  echo -e "${OK} 已删除端口 ${p} 的用户"
}

snell_multi_mod(){
  snell_multi_list
  local p; read -rp "要修改的端口: " p
  local conf="${SNELL_USERS_DIR}/snell-${p}.conf"
  [[ -f "$conf" ]] || { echo -e "${ERR} 未找到该用户配置"; return; }
  echo -e "1) 修改端口\n2) 重置 PSK\n3) 修改 DNS"
  read -rp "选择项: " sel
  case "$sel" in
    1)
      local np
      while true; do
        read -rp "新端口: " np
        [[ "$np" =~ ^[0-9]+$ && $np -ge 1 && $np -le 65535 ]] || { echo -e "${ERR} 端口非法"; continue; }
        snell_port_taken "$np" && { echo -e "${ERR} 已被 Snell 配置占用"; continue; }
        port_in_use "$np" && { echo -e "${ERR} 已被系统占用"; continue; }
        break
      done
      systemctl stop "snell-${p}" || true
      sed -i "s/listen = ::0:${p}/listen = ::0:${np}/" "$conf"
      mv "${SYSTEMD_DIR}/snell-${p}.service" "${SYSTEMD_DIR}/snell-${np}.service"
      sed -i "s/Port ${p}/Port ${np}/; s/snell-server-${p}/snell-server-${np}/; s/snell-${p}\.conf/snell-${np}.conf/" "${SYSTEMD_DIR}/snell-${np}.service"
      mv "$conf" "${SNELL_USERS_DIR}/snell-${np}.conf"
      systemctl daemon-reload
      systemctl enable "snell-${np}"
      systemctl start "snell-${np}"
      fw_open "$np"
      echo -e "${OK} 端口已改为 ${np}"
      ;;
    2)
      local npsk; npsk=$(rand_str 20)
      sed -i "s/^psk = .*/psk = ${npsk}/" "$conf"
      systemctl restart "snell-${p}"
      echo -e "${OK} 新 PSK：${npsk}"
      ;;
    3)
      local DNS
      local sysdns=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd, -)
      read -rp "新 DNS（逗号分隔，回车使用系统DNS：${sysdns:-1.1.1.1,8.8.8.8}）: " DNS || true
      [[ -z "${DNS:-}" ]] && DNS="${sysdns:-1.1.1.1,8.8.8.8}"
      if grep -q '^dns' "$conf"; then sed -i "s/^dns = .*/dns = ${DNS}/" "$conf"; else echo "dns = ${DNS}" >> "$conf"; fi
      systemctl restart "snell-${p}"
      echo -e "${OK} DNS 已更新：${DNS}"
      ;;
    *) echo -e "${ERR} 无效选择";;
  esac
}

snell_multi_view_one(){
  snell_multi_list
  local p; read -rp "要查看的端口: " p
  local conf="${SNELL_USERS_DIR}/snell-${p}.conf"
  [[ -f "$conf" ]] || { echo -e "${ERR} 未找到该用户配置"; return; }
  local port psk dns
  port=$(grep -E '^listen' "$conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
  psk=$(grep -E '^psk' "$conf" | awk -F'=' '{print $2}' | tr -d ' ')
  dns=$(grep -E '^dns' "$conf" | awk -F'=' '{print $2}' | tr -d ' ')
  echo -e "${GREEN}端口:${PLAIN} ${port}\n${GREEN}PSK :${PLAIN} ${psk}\n${GREEN}DNS :${PLAIN} ${dns}"
  local ipv4=$(get_ipv4) ipv6=$(get_ipv6) c4 c6 maj
  maj=$(snell_detect_installed_major)
  [[ -n "$ipv4" ]] && c4=$(curl -s "http://ipinfo.io/${ipv4}/country" || true) && \
    echo -e "\n${GREEN}Surge(IPv4)：${PLAIN}\n${c4:-IPV4} = snell, ${ipv4}, ${port}, psk = ${psk}, version = ${maj#v}, reuse = true, tfo = true"
  [[ -n "$ipv6" ]] && c6=$(curl -s "https://ipapi.co/${ipv6}/country/" || true) && \
    echo -e "\n${GREEN}Surge(IPv6)：${PLAIN}\n${c6:-IPV6} = snell, ${ipv6}, ${port}, psk = ${psk}, version = ${maj#v}, reuse = true, tfo = true"
}

############################################
#               SS-Rust                    #
############################################
ss_get_latest(){
  local ver
  ver=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases \
      | jq -r '[.[] | select(.prerelease==false and .draft==false) | .tag_name] | .[0]') || true
  [[ -n "$ver" && "$ver" != "null" ]] || error_exit "获取 Shadowsocks-Rust 最新版本失败"
  echo "${ver#v}"
}

ss_download_install(){
  ensure_base
  mkdir -p "$SSR_INSTALL_DIR"
  local ver="$1"; local arch; arch=$(detect_arch_ssrust)
  local base="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${ver}"
  local file="shadowsocks-v${ver}.${arch}.tar.xz"
  echo -e "${INFO} 下载 SS-Rust ${ver}\n${YELLOW}${base}/${file}${PLAIN}"
  wget --no-check-certificate -O "/tmp/${file}" "${base}/${file}" || error_exit "下载失败"
  tar -xf "/tmp/${file}" -C /tmp || error_exit "解压失败"
  rm -f "/tmp/${file}"
  [[ -f /tmp/ssserver ]] || error_exit "未找到 ssserver"
  chmod +x /tmp/ssserver
  mv -f /tmp/ssserver "$SSR_BIN"
  rm -f /tmp/sslocal /tmp/ssmanager /tmp/ssservice /tmp/ssurl 2>/dev/null || true
  echo "$ver" > "$SSR_VERSION_FILE"
  echo -e "${OK} SS-Rust 二进制安装完成"
}

ss_install_service(){
  cat >"${SYSTEMD_DIR}/ss-rust.service"<<EOF
[Unit]
Description=Shadowsocks Rust Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
ExecStart=${SSR_BIN} -c ${SSR_CONFIG}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ss-rust
  echo -e "${OK} SS-Rust 服务已安装"
}

ss_write_config(){
  local port="$1" passwd="$2" method="$3" tfo="$4" dns="$5"
  mkdir -p "$SSR_INSTALL_DIR"
  cat >"$SSR_CONFIG"<<EOF
{
  "server": "::",
  "server_port": ${port},
  "password": "${passwd}",
  "method": "${method}",
  "fast_open": ${tfo},
  "mode": "tcp_and_udp",
  "user": "nobody",
  "timeout": 300${dns:+,\n  "nameserver": "${dns}"}
}
EOF
  echo -e "${OK} 写入配置 ${SSR_CONFIG}"
}

ss_start(){ systemctl start ss-rust; sleep 1; systemctl is-active ss-rust &>/dev/null && echo -e "${OK} SS-Rust 已启动" || error_exit "SS-Rust 启动失败"; }
ss_stop(){ systemctl stop ss-rust || true; echo -e "${OK} 已停止 SS-Rust"; }
ss_restart(){ systemctl restart ss-rust || true; echo -e "${OK} 已重启 SS-Rust"; }
ss_status(){ systemctl status ss-rust --no-pager || true; }

ss_install_flow(){
  ensure_base
  [[ -x "$SSR_BIN" ]] && error_exit "检测到已安装 SS-Rust"
  local port passwd method tfo dns
  # 端口
  read -rp "SS 端口(回车随机): " port || true; [[ -z "${port:-}" ]] && port=$(rand_port)
  [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || error_exit "端口非法"
  port_in_use "$port" && error_exit "端口被占用"
  fw_open "$port"
  # 加密
  echo -e "请选择加密：\n 1) aes-128-gcm\n 2) aes-256-gcm\n 3) chacha20-ietf-poly1305\n 13) 2022-blake3-aes-128-gcm (默认)\n 14) 2022-blake3-aes-256-gcm（推荐）\n 15) 2022-blake3-chacha20-poly1305\n 16) 2022-blake3-chacha8-poly1305"
  read -rp "选择(默认13): " sel || true
  case "${sel:-13}" in
    1) method="aes-128-gcm" ;;
    2) method="aes-256-gcm" ;;
    3) method="chacha20-ietf-poly1305" ;;
    14) method="2022-blake3-aes-256-gcm" ;;
    15) method="2022-blake3-chacha20-poly1305" ;;
    16) method="2022-blake3-chacha8-poly1305" ;;
    *) method="2022-blake3-aes-128-gcm" ;;
  esac
  # 密码（按 AEAD-2022 规格）
  if [[ "$method" =~ 2022-blake3-(aes-256-gcm|chacha20-poly1305|chacha8-poly1305) ]]; then
    # 32 bytes base64
    local raw; while true; do raw=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64); [[ ${#raw} -eq 44 ]] && break; done
    passwd="$raw"
  elif [[ "$method" == "2022-blake3-aes-128-gcm" ]]; then
    passwd=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | base64)
  else
    passwd=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | base64)
  fi
  # TFO
  read -rp "启用 TCP Fast Open? (Y/n 默认Y): " t || true; [[ "${t:-Y}" =~ ^[Nn]$ ]] && tfo=false || tfo=true
  # DNS
  local sysdns=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd, -)
  read -rp "自定义 DNS(逗号分隔，回车使用系统:${sysdns:-8.8.8.8}): " dns || true
  [[ -z "${dns:-}" ]] && dns="${sysdns:-8.8.8.8}"

  local ver; ver=$(ss_get_latest)
  ss_download_install "$ver"
  ss_write_config "$port" "$passwd" "$method" "$tfo" "$dns"
  ss_install_service
  ss_start
  ss_view
}

ss_update(){
  ensure_base
  [[ -x "$SSR_BIN" ]] || error_exit "SS-Rust 未安装"
  local cur="0.0.0"; [[ -f "$SSR_VERSION_FILE" ]] && cur=$(cat "$SSR_VERSION_FILE")
  local new; new=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases | jq -r '[.[] | select(.prerelease==false and .draft==false) | .tag_name] | .[0]') || true
  [[ -n "$new" ]] || error_exit "获取最新版本失败"
  if [[ "${new#v}" == "$cur" ]]; then echo -e "${OK} 已是最新"; return 0; fi
  ss_download_install "${new#v}"
  systemctl restart ss-rust || true
  echo -e "${OK} 已更新到 ${new}"
}

ss_uninstall(){
  systemctl stop ss-rust 2>/dev/null || true
  systemctl disable ss-rust 2>/dev/null || true
  rm -f "${SYSTEMD_DIR}/ss-rust.service" "$SSR_BIN"
  rm -rf "$SSR_INSTALL_DIR"
  systemctl daemon-reload
  echo -e "${OK} 已卸载 SS-Rust"
}

ss_read_config(){
  [[ -f "$SSR_CONFIG" ]] || error_exit "配置不存在：$SSR_CONFIG"
  jq '.' "$SSR_CONFIG"
}

ss_view(){
  [[ -f "$SSR_CONFIG" ]] || { echo -e "${WARN} 未找到 SS 配置"; return 0; }
  local port passwd method tfo dns
  port=$(jq -r '.server_port' "$SSR_CONFIG")
  passwd=$(jq -r '.password' "$SSR_CONFIG")
  method=$(jq -r '.method' "$SSR_CONFIG")
  tfo=$(jq -r '.fast_open' "$SSR_CONFIG")
  dns=$(jq -r '.nameserver // empty' "$SSR_CONFIG")
  local ipv4=$(get_ipv4) ipv6=$(get_ipv6)
  echo -e "端口: ${port}\n加密: ${method}\nTFO : ${tfo}\nDNS : ${dns:-系统默认}"

  local userinfo; userinfo=$(printf "%s:%s" "$method" "$passwd" | base64 -w 0)
  [[ -n "$ipv4" ]] && echo -e "\n${GREEN}SS 链接(IPv4)：${PLAIN}\nss://${userinfo}@${ipv4}:${port}#SS-${ipv4}"
  [[ -n "$ipv6" ]] && echo -e "\n${GREEN}SS 链接(IPv6)：${PLAIN}\nss://${userinfo}@${ipv6}:${port}#SS-${ipv6}"

  # ShadowTLS 组合（shadowtls-ss.service）
  local svc="${SYSTEMD_DIR}/shadowtls-ss.service"
  if [[ -f "$svc" ]]; then
    local listen sni pwd; listen=$(grep -oP '(?<=--listen ::0:)\d+' "$svc")
    sni=$(grep -oP '(?<=--tls )\S+' "$svc"); pwd=$(grep -oP '(?<=--password )\S+' "$svc")
    [[ -n "$listen" && -n "$sni" && -n "$pwd" ]] && {
      echo -e "\n${YELLOW}=== ShadowTLS 组合 ===${PLAIN}\n监听：${listen}\nSNI：${sni}\n版本：3"
      if [[ -n "$ipv4" ]]; then
        local st_json st_b64 url
        st_json=$(printf '{"version":"3","password":"%s","host":"%s","port":"%s","address":"%s"}' "$pwd" "$sni" "$listen" "$ipv4")
        st_b64=$(echo -n "$st_json" | base64 -w 0)
        url="ss://${userinfo}@${ipv4}:${port}?shadow-tls=${st_b64}#SS-${ipv4}"
        echo -e "${GREEN}合并链接：${PLAIN}${url}"
        command -v qrencode &>/dev/null && { echo -e "${GREEN}二维码：${PLAIN}"; echo -n "$url" | qrencode -t UTF8; }
        echo -e "\n${GREEN}Surge：${PLAIN}\nss, ${ipv4}, ${listen}, encrypt-method=${method}, password=${passwd}, shadow-tls-password=${pwd}, shadow-tls-sni=${sni}, shadow-tls-version=3, udp-relay=true"
        echo -e "\nClash Meta：\nproxies:\n  - name: SS-${ipv4}\n    type: ss\n    server: ${ipv4}\n    port: ${listen}\n    cipher: ${method}\n    password: \"${passwd}\"\n    plugin: shadow-tls\n    plugin-opts:\n      host: \"${sni}\"\n      password: \"${pwd}\"\n      version: 3"
      fi
    }
  fi
}

ss_modify(){
  [[ -f "$SSR_CONFIG" ]] || error_exit "未安装/未配置"
  echo -e "1) 端口  2) 密码  3) 加密  4) TFO  5) DNS  6) 全改"
  read -rp "选择: " m
  local port passwd method tfo dns
  # 先读取旧值
  port=$(jq -r '.server_port' "$SSR_CONFIG")
  passwd=$(jq -r '.password' "$SSR_CONFIG")
  method=$(jq -r '.method' "$SSR_CONFIG")
  tfo=$(jq -r '.fast_open' "$SSR_CONFIG")
  dns=$(jq -r '.nameserver // empty' "$SSR_CONFIG")

  case "$m" in
    1) read -rp "新端口: " port ;;
    2) read -rp "新密码(回车随机): " passwd; [[ -z "${passwd:-}" ]] && passwd=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | base64) ;;
    3)
      echo -e "与安装同样选项（13/14/15/16 等）"; read -rp "新加密: " s; case "${s:-13}" in
        1) method="aes-128-gcm" ;; 2) method="aes-256-gcm" ;; 3) method="chacha20-ietf-poly1305" ;;
        14) method="2022-blake3-aes-256-gcm" ;; 15) method="2022-blake3-chacha20-poly1305" ;;
        16) method="2022-blake3-chacha8-poly1305" ;; *) method="2022-blake3-aes-128-gcm" ;;
      esac
      ;;
    4) read -rp "TFO true/false: " tfo ;;
    5) read -rp "DNS(逗号分隔，留空用系统): " dns ;;
    6)
      read -rp "端口: " port
      read -rp "密码(回车随机): " passwd; [[ -z "${passwd:-}" ]] && passwd=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | base64)
      echo -e "加密同安装，输入编号"; read -rp "加密(默认13): " s; case "${s:-13}" in
        1) method="aes-128-gcm" ;; 2) method="aes-256-gcm" ;; 3) method="chacha20-ietf-poly1305" ;;
        14) method="2022-blake3-aes-256-gcm" ;; 15) method="2022-blake3-chacha20-poly1305" ;;
        16) method="2022-blake3-chacha8-poly1305" ;; *) method="2022-blake3-aes-128-gcm" ;;
      esac
      read -rp "TFO true/false(默认true): " tfo; [[ -z "${tfo:-}" ]] && tfo=true
      local sysdns=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd, -)
      read -rp "DNS(留空:${sysdns:-8.8.8.8}): " dns; [[ -z "${dns:-}" ]] && dns="${sysdns:-8.8.8.8}"
      ;;
    *) echo -e "${ERR} 无效选择"; return ;;
  esac

  [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] || error_exit "端口非法"
  ss_write_config "$port" "$passwd" "$method" "${tfo:-true}" "$dns"
  ss_restart
}

############################################
#               ShadowTLS                  #
############################################
stls_latest(){
  local ver; ver=$(curl -s https://api.github.com/repos/ihciah/shadow-tls/releases/latest | jq -r .tag_name)
  [[ -n "$ver" && "$ver" != "null" ]] || error_exit "获取 ShadowTLS 最新版本失败"
  echo "$ver"
}
stls_arch(){
  local m=$(uname -m)
  case "$m" in
    x86_64) echo "x86_64-unknown-linux-musl" ;;
    aarch64) echo "aarch64-unknown-linux-musl" ;;
    *) error_exit "ShadowTLS 暂不支持架构: $m" ;;
  esac
}
stls_install(){
  ensure_base
  local ver arch url
  ver=$(stls_latest); arch=$(stls_arch)
  url="https://github.com/ihciah/shadow-tls/releases/download/${ver}/shadow-tls-${arch}"
  echo -e "${INFO} 下载 ShadowTLS ${ver}\n${YELLOW}${url}${PLAIN}"
  wget -O /tmp/shadow-tls.tmp "$url" || error_exit "下载失败"
  mv /tmp/shadow-tls.tmp "$STLS_BIN"; chmod +x "$STLS_BIN"
  echo -e "${OK} ShadowTLS 安装完成"
}
stls_svc_ss(){
  local backend_port="$1" listen_port="$2" sni="$3" pwd="$4"
  cat >"${SYSTEMD_DIR}/shadowtls-ss.service"<<EOF
[Unit]
Description=Shadow-TLS Server Service for Shadowsocks
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${STLS_BIN} --v3 server --listen ::0:${listen_port} --server 127.0.0.1:${backend_port} --tls ${sni} --password ${pwd}
StandardOutput=append:/var/log/shadowtls-ss.log
StandardError=append:/var/log/shadowtls-ss.log
SyslogIdentifier=shadow-tls-ss
Restart=always
RestartSec=3
LimitNOFILE=65535
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF
}
stls_svc_snell(){
  local snell_port="$1" listen_port="$2" sni="$3" pwd="$4"
  cat >"${SYSTEMD_DIR}/shadowtls-snell-${snell_port}.service"<<EOF
[Unit]
Description=Shadow-TLS Server Service for Snell (Port: ${snell_port})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${STLS_BIN} --v3 server --listen ::0:${listen_port} --server 127.0.0.1:${snell_port} --tls ${sni} --password ${pwd}
StandardOutput=append:/var/log/shadowtls-snell-${snell_port}.log
StandardError=append:/var/log/shadowtls-snell-${snell_port}.log
SyslogIdentifier=shadow-tls-snell-${snell_port}
Restart=always
RestartSec=3
LimitNOFILE=65535
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF
}
stls_add(){
  [[ -x "$STLS_BIN" ]] || stls_install
  echo -e "选择配置对象：\n 1) Shadowsocks\n 2) Snell\n 3) 两者"
  read -rp "选择: " ch
  local sni pwd; read -rp "TLS 伪装域名(默认 www.microsoft.com): " sni; sni=${sni:-www.microsoft.com}
  pwd=$(rand_str 16)
  local ip4=$(get_ipv4)

  if [[ "$ch" == "1" || "$ch" == "3" ]]; then
    [[ -f "$SSR_CONFIG" ]] || error_exit "未找到 SS 配置，先安装 SS-Rust"
    local ss_port; ss_port=$(jq -r '.server_port' "$SSR_CONFIG")
    local lp; read -rp "ShadowTLS(SS) 监听端口(回车随机): " lp; [[ -z "${lp:-}" ]] && lp=$(rand_port)
    stls_svc_ss "$ss_port" "$lp" "$sni" "$pwd"
    systemctl daemon-reload; systemctl enable shadowtls-ss; systemctl restart shadowtls-ss
    echo -e "${OK} 已配置 SS + ShadowTLS @ ${lp}"
    # 输出
    local method passwd; method=$(jq -r '.method' "$SSR_CONFIG"); passwd=$(jq -r '.password' "$SSR_CONFIG")
    local userinfo st_json b64 url
    userinfo=$(printf "%s:%s" "$method" "$passwd" | base64 -w 0)
    st_json=$(printf '{"version":"3","password":"%s","host":"%s","port":"%s","address":"%s"}' "$pwd" "$sni" "$lp" "$ip4")
    b64=$(echo -n "$st_json" | base64 -w 0)
    url="ss://${userinfo}@${ip4}:${ss_port}?shadow-tls=${b64}#SS-${ip4}"
    echo -e "${GREEN}SS+ShadowTLS 链接：${PLAIN}${url}"
  fi

  if [[ "$ch" == "2" || "$ch" == "3" ]]; then
    [[ -f "$SNELL_MAIN_CONF" || -d "$SNELL_USERS_DIR" ]] || error_exit "未找到 Snell 配置，先安装 Snell"
    echo -e "${YELLOW}选择 Snell 端口：${PLAIN}"
    local ports=()
    if [[ -f "$SNELL_MAIN_CONF" ]]; then
      local mp; mp=$(grep -E '^listen' "$SNELL_MAIN_CONF" | sed -n 's/.*::0:\([0-9]*\)/\1/p'); ports+=("$mp")
    fi
    if [[ -d "$SNELL_USERS_DIR" ]]; then
      while IFS= read -r p; do [[ -n "$p" ]] && ports+=("$p"); done < <(snell_ports_in_use)
    fi
    ports=($(printf "%s\n" "${ports[@]}" | sort -n | uniq))
    local i=0; for p in "${ports[@]}"; do i=$((i+1)); echo "  $i) $p"; done
    read -rp "输入序号(0 为全部): " idx
    if [[ "$idx" == "0" ]]; then
      for p in "${ports[@]}"; do
        local lp; read -rp "ShadowTLS 监听端口(针对 Snell ${p}，回车随机): " lp; [[ -z "${lp:-}" ]] && lp=$(rand_port)
        stls_svc_snell "$p" "$lp" "$sni" "$pwd"
      done
    else
      local pick="${ports[$((idx-1))]}"
      [[ -n "$pick" ]] || error_exit "无效序号"
      local lp; read -rp "ShadowTLS 监听端口(回车随机): " lp; [[ -z "${lp:-}" ]] && lp=$(rand_port)
      stls_svc_snell "$pick" "$lp" "$sni" "$pwd"
    fi
    systemctl daemon-reload
    for svc in $(ls "${SYSTEMD_DIR}"/shadowtls-snell-*.service 2>/dev/null); do
      local name=$(basename "$svc" .service)
      systemctl enable "$name"; systemctl restart "$name"
    done
    echo -e "${OK} Snell + ShadowTLS 配置完成"
  fi
}

stls_view(){
  local ip4=$(get_ipv4)
  local ss_svc="${SYSTEMD_DIR}/shadowtls-ss.service"
  [[ -f "$ss_svc" ]] && {
    local lp sni pwd; lp=$(grep -oP '(?<=--listen ::0:)\d+' "$ss_svc")
    sni=$(grep -oP '(?<=--tls )\S+' "$ss_svc"); pwd=$(grep -oP '(?<=--password )\S+' "$ss_svc")
    echo -e "\n${YELLOW}[SS + ShadowTLS]${PLAIN}\n监听：${lp}\nSNI：${sni}\n密码：${pwd}"
  }
  local sn_svc=$(find "$SYSTEMD_DIR" -maxdepth 1 -name "shadowtls-snell-*.service" 2>/dev/null | sort -u || true)
  [[ -n "$sn_svc" ]] && {
    echo -e "\n${YELLOW}[Snell + ShadowTLS]${PLAIN}"
    while IFS= read -r s; do
      [[ -n "$s" ]] || continue
      local stp sni pwd sp exec
      exec=$(grep ExecStart= "$s")
      stp=$(echo "$exec" | grep -oP '(?<=--listen ::0:)\d+')
      sni=$(echo "$exec" | grep -oP '(?<=--tls )\S+')
      pwd=$(echo "$exec" | grep -oP '(?<=--password )\S+')
      sp=$(echo "$exec" | grep -oP '(?<=--server 127.0.0.1:)\d+')
      echo -e "Snell 端口：${sp}  |  STLS：${stp}  |  SNI：${sni}  |  密码：${pwd}"
    done <<< "$sn_svc"
  }
  [[ ! -f "$ss_svc" && -z "$sn_svc" ]] && echo -e "${WARN} 未配置任何 ShadowTLS 服务"
}

stls_restart_all(){
  [[ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]] && systemctl restart shadowtls-ss || true
  for s in $(ls "${SYSTEMD_DIR}"/shadowtls-snell-*.service 2>/dev/null || true); do
    systemctl restart "$(basename "$s" .service)" || true
  done
  echo -e "${OK} ShadowTLS 服务已重启"
}

stls_uninstall(){
  [[ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]] && { systemctl stop shadowtls-ss; systemctl disable shadowtls-ss; rm -f "${SYSTEMD_DIR}/shadowtls-ss.service"; }
  for s in $(ls "${SYSTEMD_DIR}"/shadowtls-snell-*.service 2>/dev/null || true); do
    systemctl stop "$(basename "$s" .service)" || true
    systemctl disable "$(basename "$s" .service)" || true
    rm -f "$s"
  done
  rm -f "$STLS_BIN"
  systemctl daemon-reload
  echo -e "${OK} 已卸载 ShadowTLS 及其服务"
}

############################################
#                 BBR (可选)               #
############################################
bbr_manage(){
  echo -e "${INFO} 获取并执行 BBR 管理脚本（你的原地址）"
  bash <(curl -sL https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/bbr.sh)
}

############################################
#                 菜单系统                #
############################################
pause_read(){ echo -e "\n${YELLOW}按回车返回菜单…${PLAIN}"; read -r _; }

menu_snell(){
  while true; do
    clear
    echo -e "${CYAN}===== Snell 管理 =====${PLAIN}"
    echo "1) 安装  2) 卸载  3) 查看  4) 重启"
    echo "5) 检查并升级二进制  6) 状态"
    echo "---- 多用户 ----"
    echo "7) 列表  8) 新增  9) 删除  10) 修改  11) 查看单个"
    echo "0) 返回"
    read -rp "选择: " a
    case "$a" in
      1) snell_install; pause_read ;;
      2) snell_uninstall; pause_read ;;
      3) snell_view; pause_read ;;
      4) snell_restart; pause_read ;;
      5) snell_update_binary; pause_read ;;
      6) snell_status; pause_read ;;
      7) snell_multi_list; pause_read ;;
      8) snell_multi_add; pause_read ;;
      9) snell_multi_del; pause_read ;;
      10) snell_multi_mod; pause_read ;;
      11) snell_multi_view_one; pause_read ;;
      0) break ;;
      *) echo -e "${ERR} 无效选择"; sleep 1 ;;
    esac
  done
}

menu_ssrust(){
  while true; do
    clear
    echo -e "${CYAN}===== Shadowsocks-Rust 管理 =====${PLAIN}"
    echo "1) 安装  2) 更新  3) 卸载"
    echo "4) 启动  5) 停止  6) 重启  7) 状态"
    echo "8) 修改配置  9) 查看配置/链接"
    echo "0) 返回"
    read -rp "选择: " a
    case "$a" in
      1) ss_install_flow; pause_read ;;
      2) ss_update; pause_read ;;
      3) ss_uninstall; pause_read ;;
      4) ss_start; pause_read ;;
      5) ss_stop; pause_read ;;
      6) ss_restart; pause_read ;;
      7) ss_status; pause_read ;;
      8) ss_modify; pause_read ;;
      9) ss_view; pause_read ;;
      0) break ;;
      *) echo -e "${ERR} 无效选择"; sleep 1 ;;
    esac
  done
}

menu_shadowtls(){
  while true; do
    clear
    echo -e "${CYAN}===== ShadowTLS 管理 =====${PLAIN}"
    echo "1) 安装/升级  2) 卸载"
    echo "3) 查看配置   4) 新增配置"
    echo "5) 重启全部服务"
    echo "0) 返回"
    read -rp "选择: " a
    case "$a" in
      1) stls_install; pause_read ;;
      2) stls_uninstall; pause_read ;;
      3) stls_view; pause_read ;;
      4) stls_add; pause_read ;;
      5) stls_restart_all; pause_read ;;
      0) break ;;
      *) echo -e "${ERR} 无效选择"; sleep 1 ;;
    esac
  done
}

main_menu(){
  check_root; ensure_base; snell_migrate_old
  while true; do
    clear
    echo -e "${CYAN}============================================${PLAIN}"
    echo -e "${CYAN}     代理管理套件 (All-in-One) v${SCRIPT_VERSION} ${PLAIN}"
    echo -e "${CYAN}============================================${PLAIN}"
    echo " 1) Snell 管理"
    echo " 2) Shadowsocks-Rust 管理"
    echo " 3) ShadowTLS 管理"
    echo " 4) BBR 管理（可选，调用你原来脚本）"
    echo " 0) 退出"
    read -rp "选择: " n
    case "$n" in
      1) menu_snell ;;
      2) menu_ssrust ;;
      3) menu_shadowtls ;;
      4) bbr_manage; pause_read ;;
      0) echo -e "${OK} Bye."; exit 0 ;;
      *) echo -e "${ERR} 无效选择"; sleep 1 ;;
    esac
  done
}

main_menu
