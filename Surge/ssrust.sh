#!/usr/bin/env bash
# =========================================================
# 合并版管理脚本：SS-Rust（仅 AEAD 2022）+ Snell + ShadowTLS
# 要求点：
#  - 主菜单顺序：SS-Rust -> Snell -> ShadowTLS
#  - 去掉二维码输出
#  - Snell 以给定版本为母体（含 KB 抓取 + beta 优先）
#  - 输入 `ssrust` 或 `snell` 都能进入同一菜单（自动创建别名）
# =========================================================

# ============== 颜色和全局版本 ==============
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
current_version="6.0-merged"

# ============== 路径 ==============
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

# ---- Snell
SNELL_VERSION=""
SNELL_BIN="${INSTALL_DIR}/snell-server"
SNELL_CONF_DIR="/etc/snell"
SNELL_USERS_DIR="${SNELL_CONF_DIR}/users"
SNELL_MAIN_CONF="${SNELL_USERS_DIR}/snell-main.conf"
SNELL_SERVICE="${SYSTEMD_DIR}/snell.service"
OLD_SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
OLD_SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"

# ---- ShadowTLS
STLS_BIN="${INSTALL_DIR}/shadow-tls"
STLS_SS_SERVICE="${SYSTEMD_DIR}/shadowtls-ss.service"

# ---- SS-Rust
SSR_INSTALL_DIR="/etc/ss-rust"
SSR_BIN="${INSTALL_DIR}/ss-rust"
SSR_CONF="${SSR_INSTALL_DIR}/config.json"
SSR_VER_FILE="${SSR_INSTALL_DIR}/ver.txt"
SSR_SERVICE="${SYSTEMD_DIR}/ss-rust.service"

# ============== 基础工具 & 环境 ==============
wait_for_apt() {
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    echo -e "${YELLOW}等待其他 apt 进程完成...${RESET}"; sleep 1
  done
}
check_root() {
  if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}请以 root 权限运行此脚本${RESET}"; exit 1
  fi
}
check_and_install() {
  local tool=$1 pkg=${2:-$1}
  if ! command -v "$tool" &>/dev/null; then
    echo -e "${YELLOW}未检测到 ${tool}，正在安装...${RESET}"
    if command -v apt &>/dev/null; then
      wait_for_apt; apt update && apt install -y "$pkg"
    elif command -v yum &>/dev/null; then
      yum install -y "$pkg"
    else
      echo -e "${RED}未支持的包管理器，无法安装 ${pkg}${RESET}"; exit 1
    fi
  fi
}
ensure_min_tools() {
  for t in curl jq bc; do check_and_install "$t"; done
}
ensure_aliases() {
  # 让 vps 输入 ssrust 或 snell 都能进入此菜单
  local self
  self="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
  for alias in ssrust snell; do
    cat > "${INSTALL_DIR}/${alias}" <<EOF
#!/usr/bin/env bash
exec "${self}" "\$@"
EOF
    chmod +x "${INSTALL_DIR}/${alias}" || true
  done
}

# ============== 通用函数 ==============
open_port() {
  local PORT=$1
  if command -v ufw &>/dev/null; then
    echo -e "${CYAN}UFW 开放端口 ${PORT}${RESET}"
    ufw allow "${PORT}"/tcp >/dev/null 2>&1 || true
    ufw allow "${PORT}"/udp >/dev/null 2>&1 || true
  fi
  if command -v iptables &>/dev/null; then
    echo -e "${CYAN}iptables 开放端口 ${PORT}${RESET}"
    iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
    [ ! -d "/etc/iptables" ] && mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
}
get_ipv4() { curl -s4 --max-time 3 https://api.ipify.org; }
get_ipv6() { curl -s6 --max-time 3 https://api64.ipify.org; }

# ============== Snell：版本抓取 & 下载地址 ==============
get_latest_snell_version() {
  local url="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"
  local html v_beta v_stable
  html=$(curl -fsSL --connect-timeout 5 -m 10 "$url") || return 1
  v_beta=$(printf '%s' "$html" \
    | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+b[0-9]+' \
    | sed -E 's/^snell-server-v//' \
    | sed -E 's/b([0-9]+)/-beta.\1/' \
    | sort -V | tail -n1 \
    | sed -E 's/-beta\.([0-9]+)/b\1/')
  if [ -n "$v_beta" ]; then echo "v${v_beta}"; return 0; fi
  v_stable=$(printf '%s' "$html" \
    | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+' \
    | sed -E 's/^snell-server-v//' \
    | sort -V | tail -n1)
  [ -n "$v_stable" ] && echo "v${v_stable}" && return 0
  return 1
}
get_snell_download_url() {
  local version="$1" arch; arch=$(uname -m)
  case ${arch} in
    x86_64|amd64)  echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-amd64.zip" ;;
    i386|i686)     echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-i386.zip" ;;
    aarch64|arm64) echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-aarch64.zip" ;;
    armv7l|armv7)  echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-armv7l.zip" ;;
    *) echo -e "${RED}Snell 不支持的架构: ${arch}${RESET}" >&2; return 1 ;;
  esac
}
detect_installed_snell_version() {
  if command -v snell-server &>/dev/null; then
    local version_output main_version
    version_output=$(snell-server --v 2>&1)
    main_version=$(echo "$version_output" | grep -oP 'v[0-9]+' | head -n1)
    [ -n "$main_version" ] && echo "$main_version" || echo "unknown"
  else
    echo "unknown"
  fi
}
get_current_snell_version() {
  if ! command -v snell-server &>/dev/null; then
    echo -e "${RED}Snell 未安装${RESET}"; return 1
  fi
  CURRENT_VERSION=$(snell-server --v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*')
  [ -z "$CURRENT_VERSION" ] && { echo -e "${RED}无法获取当前 Snell 版本${RESET}"; return 1; }
}
version_greater_equal() {
  local ver1=$1 ver2=$2
  ver1=$(echo "${ver1#[vV]}" | tr '[:upper:]' '[:lower:]' | sed 's/b\([0-9]\+\)/\.999\1/g')
  ver2=$(echo "${ver2#[vV]}" | tr '[:upper:]' '[:lower:]' | sed 's/b\([0-9]\+\)/\.999\1/g')
  IFS='.' read -ra V1 <<<"$ver1"; IFS='.' read -ra V2 <<<"$ver2"
  while [ ${#V1[@]} -lt 4 ]; do V1+=("0"); done
  while [ ${#V2[@]} -lt 4 ]; do V2+=("0"); done
  for i in {0..3}; do
    local a=${V1[i]:-0} b=${V2[i]:-0}
    if [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]]; then
      [ "$a" -gt "$b" ] && return 0
      [ "$a" -lt "$b" ] && return 1
    else
      [[ "$a" > "$b" ]] && return 0
      [[ "$a" < "$b" ]] && return 1
    fi
  done
  return 0
}

# ============== Snell：配置/备份/迁移 ==============
backup_snell_config() {
  local dir="/etc/snell/backup_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$dir"; cp -a ${SNELL_USERS_DIR}/*.conf "$dir"/ 2>/dev/null; echo "$dir"
}
restore_snell_config() {
  local dir="$1"
  [ -d "$dir" ] && cp -a "$dir"/*.conf ${SNELL_USERS_DIR}/ 2>/dev/null && \
    echo -e "${GREEN}已从备份恢复${RESET}" || echo -e "${RED}未找到备份目录${RESET}"
}
get_snell_port_main() {
  [ -f "${SNELL_MAIN_CONF}" ] && grep -E '^listen' "${SNELL_MAIN_CONF}" | sed -n 's/.*::0:\([0-9]*\)/\1/p'
}
check_and_migrate_snell() {
  local old=false
  if [ -f "$OLD_SNELL_CONF_FILE" ] || [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
    old=true
    echo -e "${YELLOW}检测到旧版 Snell 配置，是否迁移？[y/N]${RESET}"
    read -r c
    if [[ "$c" =~ ^[Yy]$ ]]; then
      systemctl stop snell 2>/dev/null || true
      mkdir -p "${SNELL_USERS_DIR}"
      [ -f "$OLD_SNELL_CONF_FILE" ] && cp "$OLD_SNELL_CONF_FILE" "${SNELL_MAIN_CONF}"
      if [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
        sed -e "s|${OLD_SNELL_CONF_FILE}|${SNELL_MAIN_CONF}|g" "$OLD_SYSTEMD_SERVICE_FILE" > "$SNELL_SERVICE"
      fi
      systemctl daemon-reload
      systemctl start snell 2>/dev/null || true
      echo -e "${GREEN}迁移完成${RESET}"
    fi
  fi
}

# ============== Snell：安装/卸载/查看/更新 ==============
snell_install() {
  echo -e "${CYAN}安装 Snell...${RESET}"
  for t in wget unzip; do check_and_install "$t"; done
  SNELL_VERSION=$(get_latest_snell_version) || { echo -e "${RED}获取版本失败${RESET}"; return 1; }
  local url; url=$(get_snell_download_url "$SNELL_VERSION") || return 1
  echo -e "${YELLOW}下载：${url}${RESET}"
  wget -O /tmp/snell.zip "$url" || { echo -e "${RED}下载失败${RESET}"; return 1; }
  unzip -o /tmp/snell.zip -d "${INSTALL_DIR}" || { echo -e "${RED}解压失败${RESET}"; rm -f /tmp/snell.zip; return 1; }
  rm -f /tmp/snell.zip; chmod +x "${SNELL_BIN}"
  mkdir -p "${SNELL_USERS_DIR}"

  # 端口 & psk
  local PORT PSK
  while true; do
    read -rp "请输入 Snell 端口 (1-65535，回车随机): " PORT
    if [[ -z "$PORT" ]]; then PORT=$(shuf -i 30000-39999 -n1); echo -e "${GREEN}随机端口: ${PORT}${RESET}"; break
    elif [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]]; then break
    else echo -e "${RED}端口无效${RESET}"; fi
  done
  PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

  cat > "${SNELL_MAIN_CONF}" <<EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = true
EOF

  cat > "${SNELL_SERVICE}" <<EOF
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

  systemctl daemon-reload && systemctl enable snell && systemctl restart snell
  open_port "${PORT}"

  echo -e "\n${GREEN}Snell 安装完成${RESET}"
  local ver installed_version; installed_version=$(detect_installed_snell_version)
  local ip4 ip6; ip4=$(get_ipv4); ip6=$(get_ipv6)
  [ -n "$ip4" ] && echo -e "${GREEN}(IPv4)${RESET} snell, ${ip4}, ${PORT}, psk=${PSK}, version=${installed_version#[vV]}, reuse=true, tfo=true"
  [ -n "$ip6" ] && echo -e "${GREEN}(IPv6)${RESET} snell, ${ip6}, ${PORT}, psk=${PSK}, version=${installed_version#[vV]}, reuse=true, tfo=true"

  ensure_aliases
}
snell_uninstall() {
  echo -e "${CYAN}卸载 Snell...${RESET}"
  systemctl stop snell 2>/dev/null || true
  systemctl disable snell 2>/dev/null || true
  # 停掉多用户
  if [ -d "${SNELL_USERS_DIR}" ]; then
    for c in "${SNELL_USERS_DIR}"/*; do
      if [ -f "$c" ] && [[ "$c" != *"snell-main.conf" ]]; then
        local p; p=$(grep -E '^listen' "$c" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        [ -n "$p" ] && systemctl disable "snell-${p}" 2>/dev/null && systemctl stop "snell-${p}" 2>/dev/null && rm -f "${SYSTEMD_DIR}/snell-${p}.service"
      fi
    done
  fi
  rm -f "${SNELL_SERVICE}" "${SNELL_BIN}"
  rm -rf "${SNELL_CONF_DIR}"
  systemctl daemon-reload
  echo -e "${GREEN}Snell 已卸载${RESET}"
}
snell_view() {
  echo -e "${CYAN}Snell 配置查看${RESET}"
  local installed_version; installed_version=$(detect_installed_snell_version)
  [ "$installed_version" != "unknown" ] && echo -e "${YELLOW}已安装版本: ${installed_version}${RESET}"
  local ip4 ip6; ip4=$(get_ipv4); ip6=$(get_ipv6)
  local show_one() {
    local conf="$1" name="$2"
    [ ! -f "$conf" ] && return
    local port psk ipv6
    port=$(grep -E '^listen' "$conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
    psk=$(grep -E '^psk' "$conf" | awk -F'=' '{print $2}' | tr -d ' ')
    ipv6=$(grep -E '^ipv6' "$conf" | awk -F'=' '{print $2}' | tr -d ' ')
    echo -e "\n${GREEN}${name}${RESET} 端口:${port}  PSK:${psk}  IPv6:${ipv6}"
    [ -n "$ip4" ] && echo -e "Surge(IPv4): snell, ${ip4}, ${port}, psk=${psk}, version=${installed_version#[vV]}, reuse=true, tfo=true"
    [ -n "$ip6" ] && echo -e "Surge(IPv6): snell, ${ip6}, ${port}, psk=${psk}, version=${installed_version#[vV]}, reuse=true, tfo=true"
  }
  show_one "${SNELL_MAIN_CONF}" "主用户"
  if [ -d "${SNELL_USERS_DIR}" ]; then
    for conf in "${SNELL_USERS_DIR}"/*; do
      [[ "$conf" == *"snell-main.conf" ]] && continue
      [ -f "$conf" ] && show_one "$conf" "用户($(basename "$conf"))"
    done
  fi

  # ShadowTLS 组合（如果存在）
  local services; services=$(find "${SYSTEMD_DIR}" -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
  if [ -n "$services" ]; then
    echo -e "\n${YELLOW}=== ShadowTLS 组合配置 ===${RESET}"
    while IFS= read -r svc; do
      local exec stls_port stls_pwd stls_sni snell_port
      exec=$(grep "ExecStart=" "$svc")
      stls_port=$(echo "$exec" | grep -oP '(?<=--listen ::0:)\d+')
      stls_pwd=$(echo "$exec" | grep -oP '(?<=--password )[^ ]+')
      stls_sni=$(echo "$exec" | grep -oP '(?<=--tls )[^ ]+')
      snell_port=$(echo "$exec" | grep -oP '(?<=--server 127.0.0.1:)\d+')
      [ -z "$snell_port" ] && continue
      local psk=""
      if [ -f "${SNELL_USERS_DIR}/snell-${snell_port}.conf" ]; then
        psk=$(grep -E '^psk' "${SNELL_USERS_DIR}/snell-${snell_port}.conf" | awk -F'=' '{print $2}' | tr -d ' ')
      elif [ -f "${SNELL_MAIN_CONF}" ] && [ "$snell_port" = "$(get_snell_port_main)" ]; then
        psk=$(grep -E '^psk' "${SNELL_MAIN_CONF}" | awk -F'=' '{print $2}' | tr -d ' ')
      fi
      echo -e "\nSnell端口:${snell_port}  STLS监听:${stls_port}  STLS密码:${stls_pwd}  SNI:${stls_sni}"
      [ -n "$ip4" ] && echo -e "Surge: snell, ${ip4}, ${stls_port}, psk=${psk}, version=${installed_version#[vV]}, reuse=true, tfo=true, shadow-tls-password=${stls_pwd}, shadow-tls-sni=${stls_sni}, shadow-tls-version=3"
      [ -n "$ip6" ] && echo -e "Surge: snell, ${ip6}, ${stls_port}, psk=${psk}, version=${installed_version#[vV]}, reuse=true, tfo=true, shadow-tls-password=${stls_pwd}, shadow-tls-sni=${stls_sni}, shadow-tls-version=3"
    done <<<"$services"
  fi
}
snell_restart() {
  echo -e "${YELLOW}重启 Snell...${RESET}"
  systemctl restart snell 2>/dev/null && echo -e "${GREEN}主服务已重启${RESET}" || echo -e "${RED}主服务重启失败${RESET}"
  if [ -d "${SNELL_USERS_DIR}" ]; then
    for conf in "${SNELL_USERS_DIR}"/*; do
      [[ "$conf" == *"snell-main.conf" ]] && continue
      [ -f "$conf" ] || continue
      local p; p=$(grep -E '^listen' "$conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
      [ -n "$p" ] && systemctl restart "snell-${p}" 2>/dev/null || true
    done
  fi
}
snell_check_update() {
  echo -e "${CYAN}检查 Snell 更新...${RESET}"
  local cur_major; cur_major=$(detect_installed_snell_version)
  [ "$cur_major" = "unknown" ] && { echo -e "${RED}未检测到已安装版本${RESET}"; return 1; }
  get_current_snell_version || return 1
  SNELL_VERSION=$(get_latest_snell_version) || { echo -e "${RED}获取远端版本失败${RESET}"; return 1; }
  echo -e "${YELLOW}当前: ${CURRENT_VERSION}  最新: ${SNELL_VERSION}${RESET}"
  if ! version_greater_equal "$CURRENT_VERSION" "$SNELL_VERSION"; then
    echo -e "${CYAN}发现新版本，是否更新？[y/N]${RESET}"; read -r c
    [[ "$c" =~ ^[Yy]$ ]] && snell_update_binary
  else
    echo -e "${GREEN}已是最新${RESET}"
  fi
}
snell_update_binary() {
  echo -e "${CYAN}更新 Snell 二进制(保留配置)...${RESET}"
  local backup; backup=$(backup_snell_config); echo -e "${YELLOW}配置备份到: ${backup}${RESET}"
  [ -z "$SNELL_VERSION" ] && SNELL_VERSION=$(get_latest_snell_version) || true
  local url; url=$(get_snell_download_url "$SNELL_VERSION") || { echo -e "${RED}URL 生成失败${RESET}"; return 1; }
  wget -O /tmp/snell.zip "$url" || { echo -e "${RED}下载失败${RESET}"; restore_snell_config "$backup"; return 1; }
  unzip -o /tmp/snell.zip -d "${INSTALL_DIR}" || { echo -e "${RED}解压失败${RESET}"; rm -f /tmp/snell.zip; restore_snell_config "$backup"; return 1; }
  rm -f /tmp/snell.zip; chmod +x "${SNELL_BIN}"
  systemctl restart snell || true
  if [ -d "${SNELL_USERS_DIR}" ]; then
    for conf in "${SNELL_USERS_DIR}"/*; do
      [[ "$conf" == *"snell-main.conf" ]] && continue
      [ -f "$conf" ] || continue
      local p; p=$(grep -E '^listen' "$conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
      [ -n "$p" ] && systemctl restart "snell-${p}" 2>/dev/null || true
    done
  fi
  echo -e "${GREEN}Snell 更新完成 -> ${SNELL_VERSION}${RESET}"
}

# ============== ShadowTLS ==============
stls_get_latest() {
  curl -s "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" | jq -r .tag_name
}
stls_arch() {
  local m; m=$(uname -m)
  case "$m" in
    x86_64) echo "x86_64-unknown-linux-musl" ;;
    aarch64) echo "aarch64-unknown-linux-musl" ;;
    *) echo "unsupported" ;;
  esac
}
stls_create_service() {
  local kind="$1" backend_port="$2" listen_port="$3" tls_domain="$4" password="$5" svc desc id
  if [ "$kind" = "ss" ]; then
    svc="${STLS_SS_SERVICE}"; desc="ShadowTLS for Shadowsocks"; id="shadow-tls-ss"
  else
    local sp="$2"; # here $2 is snell_port, shift params used accordingly by caller
    backend_port="$2"; listen_port="$3"; tls_domain="$4"; password="$5"
    svc="${SYSTEMD_DIR}/shadowtls-snell-${backend_port}.service"
    desc="ShadowTLS for Snell (${backend_port})"; id="shadow-tls-snell-${backend_port}"
  fi
  cat > "$svc" <<EOF
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment=RUST_BACKTRACE=1
Environment=RUST_LOG=info
ExecStart=${STLS_BIN} --v3 server --listen ::0:${listen_port} --server 127.0.0.1:${backend_port} --tls ${tls_domain} --password ${password}
StandardOutput=append:/var/log/${id}.log
StandardError=append:/var/log/${id}.log
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  touch "/var/log/${id}.log"; chmod 640 "/var/log/${id}.log"
}
stls_install() {
  echo -e "${CYAN}安装 ShadowTLS...${RESET}"
  for t in wget; do check_and_install "$t"; done
  local tag arch; tag=$(stls_get_latest); arch=$(stls_arch)
  [ -z "$tag" -o "$arch" = "unsupported" ] && { echo -e "${RED}无法确定版本或架构${RESET}"; return 1; }
  local url="https://github.com/ihciah/shadow-tls/releases/download/${tag}/shadow-tls-${arch}"
  wget -O /tmp/shadow-tls.tmp "${url}" || { echo -e "${RED}下载失败${RESET}"; return 1; }
  mv /tmp/shadow-tls.tmp "${STLS_BIN}" && chmod +x "${STLS_BIN}"

  local tls_domain password; read -rp "输入 TLS 伪装域名 (默认 www.microsoft.com): " tls_domain
  tls_domain=${tls_domain:-www.microsoft.com}
  password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

  echo -e "\n${YELLOW}选择配置目标：${RESET}"
  echo "1) 仅为 Shadowsocks 配置"
  echo "2) 仅为 Snell 配置"
  echo "3) 两者都配置"
  read -rp "选择 [1-3]: " ch

  if [[ "$ch" == "1" || "$ch" == "3" ]]; then
    if [ -f "${SSR_CONF}" ]; then
      local ss_port; ss_port=$(jq -r '.server_port' "${SSR_CONF}" 2>/dev/null)
      local listen
      while true; do
        read -rp "SS 的 ShadowTLS 监听端口(回车随机): " listen
        [[ -z "$listen" ]] && listen=$(shuf -i 30000-39999 -n1)
        [[ "$listen" =~ ^[0-9]+$ ]] && break || echo "端口无效"
      done
      stls_create_service "ss" "$ss_port" "$listen" "$tls_domain" "$password"
      systemctl daemon-reload; systemctl enable shadowtls-ss; systemctl restart shadowtls-ss
      open_port "$listen"
      local ip4 ip6; ip4=$(get_ipv4); ip6=$(get_ipv6)
      # 输出合并配置（不含二维码）
      if [ -f "${SSR_CONF}" ]; then
        local method pass; method=$(jq -r '.method' "${SSR_CONF}"); pass=$(jq -r '.password' "${SSR_CONF}")
        [ -n "$ip4" ] && echo -e "Surge: ss, ${ip4}, ${listen}, encrypt-method=${method}, password=${pass}, shadow-tls-password=${password}, shadow-tls-sni=${tls_domain}, shadow-tls-version=3, udp-relay=true"
        [ -n "$ip6" ] && echo -e "Surge: ss, ${ip6}, ${listen}, encrypt-method=${method}, password=${pass}, shadow-tls-password=${password}, shadow-tls-sni=${tls_domain}, shadow-tls-version=3, udp-relay=true"
      fi
    else
      echo -e "${YELLOW}未检测到 SS-Rust 配置，跳过 SS 部分${RESET}"
    fi
  fi

  if [[ "$ch" == "2" || "$ch" == "3" ]]; then
    if [ -f "${SNELL_MAIN_CONF}" ] || command -v snell-server &>/dev/null; then
      # 列出 Snell 端口集合
      declare -a plist=()
      if [ -d "${SNELL_USERS_DIR}" ]; then
        for conf in "${SNELL_USERS_DIR}"/*.conf; do
          [ -f "$conf" ] || continue
          local p; p=$(grep -E '^listen' "$conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
          [ -n "$p" ] && plist+=("$p")
        done
      fi
      if [ ${#plist[@]} -eq 0 ]; then
        echo -e "${RED}未找到 Snell 用户配置${RESET}"
      else
        echo -e "\n选择要配置的 Snell 端口："
        local i=1; for p in "${plist[@]}"; do echo "$i) $p"; i=$((i+1)); done
        echo "0) 全部配置"
        read -rp "选择: " pick
        if [ "$pick" = "0" ]; then
          for p in "${plist[@]}"; do
            local listen
            while true; do
              read -rp "为 Snell ${p} 设置 STLS 监听端口(回车随机): " listen
              [[ -z "$listen" ]] && listen=$(shuf -i 30000-39999 -n1)
              [[ "$listen" =~ ^[0-9]+$ ]] && break || echo "端口无效"
            done
            stls_create_service "snell" "$p" "$listen" "$tls_domain" "$password"
            systemctl daemon-reload; systemctl enable "shadowtls-snell-${p}"; systemctl restart "shadowtls-snell-${p}"
            open_port "$listen"
            # 输出 Surge 组合
            local ip4 ip6 ver; ip4=$(get_ipv4); ip6=$(get_ipv6); ver=$(detect_installed_snell_version)
            local psk=""
            if [ -f "${SNELL_USERS_DIR}/snell-${p}.conf" ]; then
              psk=$(grep -E '^psk' "${SNELL_USERS_DIR}/snell-${p}.conf" | awk -F'=' '{print $2}' | tr -d ' ')
            elif [ -f "${SNELL_MAIN_CONF}" ] && [ "$p" = "$(get_snell_port_main)" ]; then
              psk=$(grep -E '^psk' "${SNELL_MAIN_CONF}" | awk -F'=' '{print $2}' | tr -d ' ')
            fi
            [ -n "$ip4" ] && echo -e "Surge: snell, ${ip4}, ${listen}, psk=${psk}, version=${ver#[vV]}, reuse=true, tfo=true, shadow-tls-password=${password}, shadow-tls-sni=${tls_domain}, shadow-tls-version=3"
            [ -n "$ip6" ] && echo -e "Surge: snell, ${ip6}, ${listen}, psk=${psk}, version=${ver#[vV]}, reuse=true, tfo=true, shadow-tls-password=${password}, shadow-tls-sni=${tls_domain}, shadow-tls-version=3"
          done
        elif [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le ${#plist[@]} ]; then
          local p="${plist[$((pick-1))]}" listen
          while true; do
            read -rp "为 Snell ${p} 设置 STLS 监听端口(回车随机): " listen
            [[ -z "$listen" ]] && listen=$(shuf -i 30000-39999 -n1)
            [[ "$listen" =~ ^[0-9]+$ ]] && break || echo "端口无效"
          done
          stls_create_service "snell" "$p" "$listen" "$tls_domain" "$password"
          systemctl daemon-reload; systemctl enable "shadowtls-snell-${p}"; systemctl restart "shadowtls-snell-${p}"
          open_port "$listen"
          local ip4 ip6 ver; ip4=$(get_ipv4); ip6=$(get_ipv6); ver=$(detect_installed_snell_version)
          local psk=""
          if [ -f "${SNELL_USERS_DIR}/snell-${p}.conf" ]; then
            psk=$(grep -E '^psk' "${SNELL_USERS_DIR}/snell-${p}.conf" | awk -F'=' '{print $2}' | tr -d ' ')
          elif [ -f "${SNELL_MAIN_CONF}" ] && [ "$p" = "$(get_snell_port_main)" ]; then
            psk=$(grep -E '^psk' "${SNELL_MAIN_CONF}" | awk -F'=' '{print $2}' | tr -d ' ')
          fi
          [ -n "$ip4" ] && echo -e "Surge: snell, ${ip4}, ${listen}, psk=${psk}, version=${ver#[vV]}, reuse=true, tfo=true, shadow-tls-password=${password}, shadow-tls-sni=${tls_domain}, shadow-tls-version=3"
          [ -n "$ip6" ] && echo -e "Surge: snell, ${ip6}, ${listen}, psk=${psk}, version=${ver#[vV]}, reuse=true, tfo=true, shadow-tls-password=${password}, shadow-tls-sni=${tls_domain}, shadow-tls-version=3"
        else
          echo -e "${RED}无效选择${RESET}"
        fi
      fi
    else
      echo -e "${YELLOW}未检测到 Snell，跳过 Snell 部分${RESET}"
    fi
  fi
  echo -e "${GREEN}ShadowTLS 安装完成${RESET}"
}
stls_uninstall() {
  echo -e "${CYAN}卸载 ShadowTLS...${RESET}"
  [ -f "${STLS_SS_SERVICE}" ] && systemctl stop shadowtls-ss 2>/dev/null && systemctl disable shadowtls-ss 2>/dev/null && rm -f "${STLS_SS_SERVICE}"
  local svcs; svcs=$(find "${SYSTEMD_DIR}" -name "shadowtls-snell-*.service" 2>/dev/null)
  if [ -n "$svcs" ]; then
    while IFS= read -r s; do
      local n; n=$(basename "$s")
      systemctl stop "$n" 2>/dev/null; systemctl disable "$n" 2>/dev/null; rm -f "$s"
    done <<<"$svcs"
  fi
  rm -f "${STLS_BIN}"
  systemctl daemon-reload
  echo -e "${GREEN}ShadowTLS 已卸载${RESET}"
}
stls_view() {
  echo -e "${CYAN}ShadowTLS 配置查看${RESET}"
  local ip4 ip6; ip4=$(get_ipv4); ip6=$(get_ipv6)
  if [ -f "${STLS_SS_SERVICE}" ] && [ -f "${SSR_CONF}" ]; then
    local listen sni pwd; listen=$(grep -oP '(?<=--listen ::0:)\d+' "${STLS_SS_SERVICE}")
    sni=$(grep -oP '(?<=--tls )[^ ]+' "${STLS_SS_SERVICE}")
    pwd=$(grep -oP '(?<=--password )[^ ]+' "${STLS_SS_SERVICE}")
    local method pass; method=$(jq -r '.method' "${SSR_CONF}"); pass=$(jq -r '.password' "${SSR_CONF}")
    echo -e "\n[SS+ShadowTLS] 监听:${listen} SNI:${sni} 密码:${pwd}"
    [ -n "$ip4" ] && echo -e "Surge: ss, ${ip4}, ${listen}, encrypt-method=${method}, password=${pass}, shadow-tls-password=${pwd}, shadow-tls-sni=${sni}, shadow-tls-version=3, udp-relay=true"
    [ -n "$ip6" ] && echo -e "Surge: ss, ${ip6}, ${listen}, encrypt-method=${method}, password=${pass}, shadow-tls-password=${pwd}, shadow-tls-sni=${sni}, shadow-tls-version=3, udp-relay=true"
  fi
  local svcs; svcs=$(find "${SYSTEMD_DIR}" -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
  if [ -n "$svcs" ]; then
    echo -e "\n[Snell+ShadowTLS]"
    while IFS= read -r s; do
      local exec listen sni pwd sp
      exec=$(grep "ExecStart=" "$s")
      listen=$(echo "$exec" | grep -oP '(?<=--listen ::0:)\d+')
      pwd=$(echo "$exec" | grep -oP '(?<=--password )[^ ]+')
      sni=$(echo "$exec" | grep -oP '(?<=--tls )[^ ]+')
      sp=$(echo "$exec" | grep -oP '(?<=--server 127.0.0.1:)\d+')
      local ver psk; ver=$(detect_installed_snell_version)
      if [ -f "${SNELL_USERS_DIR}/snell-${sp}.conf" ]; then
        psk=$(grep -E '^psk' "${SNELL_USERS_DIR}/snell-${sp}.conf" | awk -F'=' '{print $2}' | tr -d ' ')
      elif [ -f "${SNELL_MAIN_CONF}" ] && [ "$sp" = "$(get_snell_port_main)" ]; then
        psk=$(grep -E '^psk' "${SNELL_MAIN_CONF}" | awk -F'=' '{print $2}' | tr -d ' ')
      fi
      echo -e "Snell端口:${sp} STLS:${listen} SNI:${sni} 密码:${pwd}"
      [ -n "$ip4" ] && echo -e "Surge: snell, ${ip4}, ${listen}, psk=${psk}, version=${ver#[vV]}, reuse=true, tfo=true, shadow-tls-password=${pwd}, shadow-tls-sni=${sni}, shadow-tls-version=3"
      [ -n "$ip6" ] && echo -e "Surge: snell, ${ip6}, ${listen}, psk=${psk}, version=${ver#[vV]}, reuse=true, tfo=true, shadow-tls-password=${pwd}, shadow-tls-sni=${sni}, shadow-tls-version=3"
    done <<<"$svcs"
  fi
}
stls_restart() {
  [ -f "${STLS_SS_SERVICE}" ] && systemctl restart shadowtls-ss
  local svcs; svcs=$(find "${SYSTEMD_DIR}" -name "shadowtls-snell-*.service" 2>/dev/null)
  [ -n "$svcs" ] && while IFS= read -r s; do
    local n; n=$(basename "$s"); systemctl restart "$n"
  done <<<"$svcs"
  echo -e "${GREEN}ShadowTLS 服务已重启${RESET}"
}

# ============== SS-Rust（仅 AEAD 2022） ==============
detect_os() {
  if [[ -f /etc/redhat-release ]]; then echo centos; return
  elif grep -qi debian /etc/issue /proc/version 2>/dev/null; then echo debian; return
  elif grep -qi ubuntu /etc/issue /proc/version 2>/dev/null; then echo ubuntu; return
  else echo unknown; fi
}
ssr_detect_arch() {
  local a; a=$(uname -m)
  case "$a" in
    x86_64) echo "x86_64-unknown-linux-gnu" ;;
    aarch64) echo "aarch64-unknown-linux-gnu" ;;
    armv7l|armv7) echo "armv7-unknown-linux-gnueabihf" ;;
    armv6l) echo "arm-unknown-linux-gnueabi" ;;
    i686|i386) echo "i686-unknown-linux-musl" ;;
    *) echo "unsupported" ;;
  esac
}
ssr_get_latest() {
  wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases | \
    jq -r '[.[] | select(.prerelease == false and .draft==false) | .tag_name] | .[0]' | sed 's/^v//'
}
ssr_download() {
  local ver="$1" arch="$2"
  local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${ver}/shadowsocks-v${ver}.${arch}.tar.xz"
  echo -e "${YELLOW}下载：${url}${RESET}"
  wget --no-check-certificate -N "${url}" -O "/tmp/ssrust.tar.xz" || return 1
  mkdir -p /tmp/ssrust && tar -xf /tmp/ssrust.tar.xz -C /tmp/ssrust || return 1
  [ -f /tmp/ssrust/ssserver ] || return 1
  mv -f /tmp/ssrust/ssserver "${SSR_BIN}" && chmod +x "${SSR_BIN}"
  rm -rf /tmp/ssrust /tmp/ssrust.tar.xz
  echo "${ver}" > "${SSR_VER_FILE}"
}
ssr_install_service() {
  cat > "${SSR_SERVICE}" <<EOF
[Unit]
Description=Shadowsocks Rust Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
ExecStart=${SSR_BIN} -c ${SSR_CONF}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable ss-rust
}
ssr_write_conf() {
  local port="$1" pass="$2" method="$3" tfo="$4" dns="$5"
  mkdir -p "${SSR_INSTALL_DIR}"
  cat > "${SSR_CONF}" <<EOF
{
  "server": "::",
  "server_port": ${port},
  "password": "${pass}",
  "method": "${method}",
  "fast_open": ${tfo},
  "mode": "tcp_and_udp",
  "user": "nobody",
  "timeout": 300${dns:+,\n  "nameserver": "${dns}"}
}
EOF
}
ssr_set_port() {
  local p
  while true; do
    read -rp "SS 端口(1-65535，回车随机): " p
    [[ -z "$p" ]] && p=$(shuf -i 30000-39999 -n1)
    [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]] && break || echo "端口无效"
  done
  echo "$p"
}
ssr_set_method_2022() {
  echo -e "${CYAN}仅保留 AEAD 2022 系列:${RESET}
  1) 2022-blake3-aes-128-gcm (默认)
  2) 2022-blake3-aes-256-gcm
  3) 2022-blake3-chacha20-poly1305
  4) 2022-blake3-chacha8-poly1305"
  read -rp "选择[1-4]: " m; m=${m:-1}
  case "$m" in
    2) echo "2022-blake3-aes-256-gcm" ;;
    3) echo "2022-blake3-chacha20-poly1305" ;;
    4) echo "2022-blake3-chacha8-poly1305" ;;
    *) echo "2022-blake3-aes-128-gcm" ;;
  esac
}
ssr_gen_key_for_method() {
  local method="$1" bytes
  case "$method" in
    2022-blake3-aes-128-gcm) bytes=16 ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|2022-blake3-chacha8-poly1305) bytes=32 ;;
    *) bytes=16 ;;
  esac
  # 生成对应字节后 Base64
  local key; key=$(dd if=/dev/urandom bs=${bytes} count=1 2>/dev/null | base64)
  # 确保 32 字节组为 44 个 base64 字符（有时会是 43/45，因为换行/填充）
  if [ "$bytes" -eq 32 ]; then
    local dlen; dlen=$(echo -n "$key" | base64 -d 2>/dev/null | wc -c)
    while [ "$dlen" -ne 32 ]; do
      key=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64)
      dlen=$(echo -n "$key" | base64 -d 2>/dev/null | wc -c)
    done
  fi
  echo "$key"
}
ssr_install() {
  echo -e "${CYAN}安装 Shadowsocks Rust（仅 AEAD 2022）${RESET}"
  # 依赖
  local os; os=$(detect_os)
  if [[ "$os" = "centos" ]]; then
    yum -y install jq gzip wget curl unzip xz openssl tar
  else
    wait_for_apt; apt update
    apt install -y jq gzip wget curl unzip xz-utils openssl tar
  fi
  # 交互
  local port method pass tfo dns
  port=$(ssr_set_port)
  method=$(ssr_set_method_2022)
  pass=$(ssr_gen_key_for_method "$method")
  read -rp "启用 TCP Fast Open? [Y/n]: " yn; [[ "$yn" =~ ^[Nn]$ ]] && tfo=false || tfo=true
  read -rp "自定义 DNS(留空=系统默认，例如 1.1.1.1,8.8.8.8): " dns

  # 下载
  local arch ver; arch=$(ssr_detect_arch); [ "$arch" = "unsupported" ] && { echo -e "${RED}不支持的架构${RESET}"; return 1; }
  ver=$(ssr_get_latest); [ -z "$ver" ] && { echo -e "${RED}获取版本失败${RESET}"; return 1; }
  ssr_download "$ver" "$arch" || { echo -e "${RED}下载失败${RESET}"; return 1; }

  # 写配置 & 服务
  ssr_write_conf "$port" "$pass" "$method" "$tfo" "$dns"
  ssr_install_service

  systemctl restart ss-rust && open_port "$port"
  echo -e "${GREEN}Shadowsocks Rust 安装完成${RESET}"
  local ip4 ip6; ip4=$(get_ipv4); ip6=$(get_ipv6)
  [ -n "$ip4" ] && echo -e "Surge(IPv4): ss, ${ip4}, ${port}, encrypt-method=${method}, password=${pass}, tfo=${tfo}, udp-relay=true"
  [ -n "$ip6" ] && echo -e "Surge(IPv6): ss, ${ip6}, ${port}, encrypt-method=${method}, password=${pass}, tfo=${tfo}, udp-relay=true"

  ensure_aliases
}
ssr_update() {
  [ -x "${SSR_BIN}" ] || { echo -e "${RED}未安装 SS-Rust${RESET}"; return 1; }
  local cur="0.0.0" new; [ -f "${SSR_VER_FILE}" ] && cur=$(cat "${SSR_VER_FILE}")
  new=$(ssr_get_latest); [ -z "$new" ] && { echo -e "${RED}获取最新版本失败${RESET}"; return 1; }
  if [ "$cur" = "$new" ]; then echo -e "${GREEN}已是最新 (${new})${RESET}"; return 0; fi
  local arch; arch=$(ssr_detect_arch); [ "$arch" = "unsupported" ] && { echo -e "${RED}架构不支持${RESET}"; return 1; }
  ssr_download "$new" "$arch" || { echo -e "${RED}下载失败${RESET}"; return 1; }
  systemctl restart ss-rust && echo -e "${GREEN}已更新至 ${new}${RESET}"
}
ssr_uninstall() {
  echo -e "${CYAN}卸载 SS-Rust...${RESET}"
  systemctl stop ss-rust 2>/dev/null || true
  systemctl disable ss-rust 2>/dev/null || true
  rm -f "${SSR_SERVICE}" "${SSR_BIN}"
  rm -rf "${SSR_INSTALL_DIR}"
  systemctl daemon-reload
  echo -e "${GREEN}SS-Rust 已卸载${RESET}"
}
ssr_start(){ systemctl start ss-rust && echo -e "${GREEN}已启动${RESET}" || echo -e "${RED}启动失败${RESET}"; }
ssr_stop(){ systemctl stop ss-rust && echo -e "${GREEN}已停止${RESET}" || true; }
ssr_restart(){ systemctl restart ss-rust && echo -e "${GREEN}已重启${RESET}" || echo -e "${RED}重启失败${RESET}"; }
ssr_view() {
  [ -f "${SSR_CONF}" ] || { echo -e "${RED}未找到配置${RESET}"; return 1; }
  local port pass method tfo dns
  port=$(jq -r '.server_port' "${SSR_CONF}")
  pass=$(jq -r '.password' "${SSR_CONF}")
  method=$(jq -r '.method' "${SSR_CONF}")
  tfo=$(jq -r '.fast_open' "${SSR_CONF}")
  dns=$(jq -r '.nameserver // empty' "${SSR_CONF}")
  local ip4 ip6; ip4=$(get_ipv4); ip6=$(get_ipv6)
  echo -e "端口:${port}  加密:${method}  TFO:${tfo}  ${dns:+DNS:${dns}}"
  [ -n "$ip4" ] && echo -e "Surge(IPv4): ss, ${ip4}, ${port}, encrypt-method=${method}, password=${pass}, tfo=${tfo}, udp-relay=true"
  [ -n "$ip6" ] && echo -e "Surge(IPv6): ss, ${ip6}, ${port}, encrypt-method=${method}, password=${pass}, tfo=${tfo}, udp-relay=true"
}
ssr_modify() {
  [ -f "${SSR_CONF}" ] || { echo -e "${RED}未安装/未配置${RESET}"; return 1; }
  echo -e "${CYAN}修改选项：${RESET}
  1) 端口
  2) 密钥(自动生成匹配算法)
  3) 加密(仅 AEAD 2022)
  4) TFO
  5) DNS
  6) 全部"
  read -rp "选择[1-6]: " ch
  local port pass method tfo dns
  port=$(jq -r '.server_port' "${SSR_CONF}")
  pass=$(jq -r '.password' "${SSR_CONF}")
  method=$(jq -r '.method' "${SSR_CONF}")
  tfo=$(jq -r '.fast_open' "${SSR_CONF}")
  dns=$(jq -r '.nameserver // empty' "${SSR_CONF}")

  case "$ch" in
    1) port=$(ssr_set_port) ;;
    2) pass=$(ssr_gen_key_for_method "$method") ;;
    3) method=$(ssr_set_method_2022); pass=$(ssr_gen_key_for_method "$method") ;;
    4) read -rp "启用 TFO? [Y/n]: " yn; [[ "$yn" =~ ^[Nn]$ ]] && tfo=false || tfo=true ;;
    5) read -rp "自定义 DNS(留空=系统默认): " dns ;;
    6) port=$(ssr_set_port); method=$(ssr_set_method_2022); pass=$(ssr_gen_key_for_method "$method")
       read -rp "启用 TFO? [Y/n]: " yn; [[ "$yn" =~ ^[Nn]$ ]] && tfo=false || tfo=true
       read -rp "自定义 DNS(留空=系统默认): " dns ;;
    *) echo "取消"; return 0 ;;
  esac
  ssr_write_conf "$port" "$pass" "$method" "$tfo" "$dns"
  open_port "$port"; systemctl restart ss-rust
  echo -e "${GREEN}修改完成${RESET}"
}

# ============== 状态面板（合并） ==============
panel_status() {
  echo -e "\n${CYAN}=============== 服务状态检查 ===============${RESET}"
  if command -v snell-server &>/dev/null; then
    local u=0 r=0 mem=0 cpu=0
    if systemctl is-active snell &>/dev/null; then
      u=$((u+1)); r=$((r+1))
      local pid=$(systemctl show -p MainPID snell | cut -d= -f2)
      [ -n "$pid" -a "$pid" != "0" ] && mem=$(ps -o rss= -p $pid 2>/dev/null) && cpu=$(ps -o %cpu= -p $pid 2>/dev/null)
    else u=$((u+1)); fi
    if [ -d "${SNELL_USERS_DIR}" ]; then
      for c in "${SNELL_USERS_DIR}"/*; do
        [[ "$c" == *"snell-main.conf" ]] && continue
        [ -f "$c" ] || continue
        local p=$(grep -E '^listen' "$c" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        [ -z "$p" ] && continue
        u=$((u+1))
        if systemctl is-active --quiet "snell-${p}"; then
          r=$((r+1))
          local upid=$(systemctl show -p MainPID "snell-${p}" | cut -d= -f2)
          [ -n "$upid" -a "$upid" != "0" ] && mem=$((mem + $(ps -o rss= -p $upid 2>/dev/null)))
        fi
      done
    fi
    printf "${GREEN}Snell 已安装${RESET}  ${YELLOW}运行：${r}/${u}${RESET}\n"
  else
    echo -e "${YELLOW}Snell 未安装${RESET}"
  fi

  if [ -x "${SSR_BIN}" ]; then
    if systemctl is-active ss-rust &>/dev/null; then
      echo -e "${GREEN}SS-Rust 运行中${RESET}"
    else
      echo -e "${YELLOW}SS-Rust 已安装但未运行${RESET}"
    fi
  else
    echo -e "${YELLOW}SS-Rust 未安装${RESET}"
  fi

  if [ -x "${STLS_BIN}" ]; then
    local total=0 run=0
    [ -f "${STLS_SS_SERVICE}" ] && total=$((total+1)) && systemctl is-active shadowtls-ss &>/dev/null && run=$((run+1))
    local svcs; svcs=$(find "${SYSTEMD_DIR}" -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ -n "$svcs" ]; then
      while IFS= read -r s; do
        total=$((total+1)); local n=$(basename "$s")
        systemctl is-active "$n" &>/dev/null && run=$((run+1))
      done <<<"$svcs"
    fi
    echo -e "${GREEN}ShadowTLS 已安装${RESET} ${YELLOW}运行：${run}/${total}${RESET}"
  else
    echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
  fi
  echo -e "${CYAN}============================================${RESET}\n"
}

# ============== 菜单 ==============
menu_ssrust() {
  while true; do
    clear; echo -e "${CYAN}==== Shadowsocks Rust 管理（仅 AEAD 2022）====${RESET}"
    panel_status
    cat <<'EOM'
1) 安装
2) 更新
3) 卸载
4) 启动
5) 停止
6) 重启
7) 查看配置
8) 修改配置
9) 返回主菜单
EOM
    read -rp "选择[1-9]: " n
    case "$n" in
      1) ssr_install ;;
      2) ssr_update ;;
      3) ssr_uninstall ;;
      4) ssr_start ;;
      5) ssr_stop ;;
      6) ssr_restart ;;
      7) ssr_view; read -n1 -sr -p "按任意键返回..." ;;
      8) ssr_modify ;;
      9) return ;;
      *) echo "无效选择" ;;
    esac
  done
}
menu_snell() {
  while true; do
    clear; echo -e "${CYAN}============ Snell 管理 ============${RESET}"
    panel_status
    cat <<'EOM'
1) 安装 Snell
2) 卸载 Snell
3) 查看配置
4) 重启服务
5) 检查并更新 Snell
6) 返回主菜单
EOM
    read -rp "选择[1-6]: " n
    case "$n" in
      1) snell_install ;;
      2) snell_uninstall ;;
      3) snell_view; read -n1 -sr -p "按任意键返回..." ;;
      4) snell_restart ;;
      5) snell_check_update ;;
      6) return ;;
      *) echo "无效选择" ;;
    esac
  done
}
menu_shadowtls() {
  while true; do
    clear; echo -e "${CYAN}=========== ShadowTLS 管理 ===========${RESET}"
    panel_status
    cat <<'EOM'
1) 安装 ShadowTLS
2) 卸载 ShadowTLS
3) 查看配置
4) 重启服务
5) 返回主菜单
EOM
    read -rp "选择[1-5]: " n
    case "$n" in
      1) stls_install ;;
      2) stls_uninstall ;;
      3) stls_view; read -n1 -sr -p "按任意键返回..." ;;
      4) stls_restart ;;
      5) return ;;
      *) echo "无效选择" ;;
    esac
  done
}

main_menu() {
  while true; do
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}    SS-Rust + Snell + ShadowTLS 管理器     ${RESET}"
    echo -e "${CYAN}                v${current_version}               ${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    panel_status
    echo -e "${YELLOW}=== 主菜单（按顺序：SS-Rust -> Snell -> ShadowTLS）===${RESET}"
    echo "1) Shadowsocks Rust"
    echo "2) Snell"
    echo "3) ShadowTLS"
    echo "0) 退出"
    read -rp "选择[0-3]: " x
    case "$x" in
      1) menu_ssrust ;;
      2) menu_snell ;;
      3) menu_shadowtls ;;
      0) echo -e "${GREEN}再见~${RESET}"; exit 0 ;;
      *) echo "无效选择" ;;
    esac
  done
}

# ============== 入口 ==============
check_root
ensure_min_tools
check_and_migrate_snell
ensure_aliases
main_menu
