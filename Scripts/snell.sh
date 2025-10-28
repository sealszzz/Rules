#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.3.4"
SCRIPT_INSTALL="/usr/local/sbin/snell.sh"
SCRIPT_LAUNCHER="/usr/local/bin/snell"
SCRIPT_REMOTE_RAW="https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Scripts/snell.sh"

SN_USER="snell"
SN_DIR="/etc/snell"
SN_STATE_DIR="/var/lib/snell"
SN_CONFIG="$SN_DIR/snell-server.conf"
SN_BIN="/usr/local/bin/snell-server"
SERVICE_NAME="snell"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${RED}请用 root 运行${RESET}"
    exit 1
  fi
}

require_pkg() {
  local pkgs=("$@") miss=()
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || miss+=("$p"); done
  if [ "${#miss[@]}" -gt 0 ]; then
    apt update && apt install -y --no-install-recommends "${miss[@]}"
  fi
}

get_latest_version() {
  local url="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"
  local html v_beta v_stable
  html=$(curl -fsSL --connect-timeout 5 -m 10 "$url") || return 1
  v_beta=$(printf '%s' "$html" \
    | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+b[0-9]+' \
    | sed -E 's/^snell-server-v//' \
    | sed -E 's/b([0-9]+)/-beta.\1/' \
    | sort -V | tail -n1 \
    | sed -E 's/-beta\.([0-9]+)/b\1/')
  if [ -n "$v_beta" ]; then
    echo "v${v_beta}"; return 0
  fi
  v_stable=$(printf '%s' "$html" \
    | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+' \
    | sed -E 's/^snell-server-v//' \
    | sort -V | tail -n1)
  [ -n "$v_stable" ] && echo "v${v_stable}"
}

get_download_url() {
  local version="$1"
  local arch; arch=$(uname -m)
  case ${arch} in
    x86_64|amd64)  echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-amd64.zip" ;;
    aarch64|arm64) echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-aarch64.zip" ;;
    armv7l|armv7)  echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-armv7l.zip" ;;
    i386|i686)     echo "https://dl.nssurge.com/snell/snell-server-${version}-linux-i386.zip" ;;
    *) echo -e "${RED}不支持的架构: ${arch}${RESET}" >&2; return 1 ;;
  esac
}

detect_installed_version() {
  if [ -x "$SN_BIN" ]; then
    "$SN_BIN" -v 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*' | head -n1 || echo "unknown"
  else
    echo "unknown"
  fi
}

normalize_ver(){ echo "$1" | sed 's/^v//'; }
version_gt(){
  [ "$(printf '%s\n%s\n' "$(normalize_ver "$1")" "$(normalize_ver "$2")" | sort -V | tail -n1)" != "$(normalize_ver "$2")" ]
}

is_active() {
  if [ ! -x "$SN_BIN" ]; then
    echo "未安装"
  elif systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "运行中"
  else
    echo "未运行"
  fi
}

ensure_user_and_dirs() {
  if ! id -u "$SN_USER" >/dev/null 2>&1; then
    useradd -r -M -d "$SN_STATE_DIR" -s /usr/sbin/nologin "$SN_USER"
  fi
  mkdir -p "$SN_STATE_DIR" "$SN_DIR"
  chown -R "$SN_USER:$SN_USER" "$SN_STATE_DIR"
  chown root:"$SN_USER" "$SN_DIR"
  chmod 750 "$SN_DIR"
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Snell Server
Documentation=https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=$SN_USER
Group=$SN_USER
Type=simple
UMask=0077
WorkingDirectory=$SN_STATE_DIR
ExecStart=$SN_BIN -c $SN_CONFIG
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
}

get_main_pid(){ systemctl show -p MainPID "$SERVICE_NAME" 2>/dev/null | cut -d= -f2; }

port_used_by_others() {
  local port="$1" pid_self pids
  pid_self="$(get_main_pid || echo 0)"
  command -v ss >/dev/null 2>&1 || require_pkg iproute2
  pids="$(ss -lntupH 2>/dev/null | awk -v P=":$port" '$4 ~ P {print $NF}' \
    | sed 's/[^0-9]/\n/g' | grep -E '^[0-9]+$' || true)"
  [ -z "$pids" ] && return 1
  while read -r p; do
    [ -z "$p" ] && continue
    if [ "$p" != "$pid_self" ] && [ "$p" != "0" ]; then return 0; fi
  done <<< "$pids"
  return 1
}

random_unused_port() {
  local port
  for i in {1..50}; do
    port=$(shuf -i 1024-65535 -n1)
    if ! port_used_by_others "$port"; then
      echo "$port"; return 0
    fi
  done
  echo 0
}

restart_and_verify() {
  systemctl daemon-reload || true
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  if ! systemctl restart "$SERVICE_NAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️ Snell 重启失败，请查看日志： journalctl -u ${SERVICE_NAME} -e --no-pager${RESET}"
    return 0
  fi
  sleep 1
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e "${GREEN}✅ Snell 已运行${RESET}"
  else
    echo -e "${YELLOW}⚠️ Snell 未在运行，请查看日志： journalctl -u ${SERVICE_NAME} -e --no-pager${RESET}"
  fi
}

show_header() {
  local curver; curver="$(detect_installed_version || echo '-')" ; [ -z "$curver" ] && curver='-'
  local status; status="$(is_active)"
  echo "================================================"
  echo "  Snell 管理界面"
  echo "  状态：$status    已装版本：$curver"
  echo "  服务名：$SERVICE_NAME   二进制：$SN_BIN"
  echo "  脚本版本：$SCRIPT_VERSION"
  echo "================================================"
}

pause(){ echo; read -rp "按回车键返回菜单..." _; }

ensure_launcher() {
  mkdir -p "$(dirname "$SCRIPT_INSTALL")"
  local self; self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  if [[ "$self" == /proc/*/fd/* || "$self" == /dev/fd/* ]]; then
    curl -fsSL "$SCRIPT_REMOTE_RAW" -o "$SCRIPT_INSTALL"
    chmod +x "$SCRIPT_INSTALL"
  else
    if [ "$self" != "$SCRIPT_INSTALL" ]; then cp -f "$self" "$SCRIPT_INSTALL"; fi
    chmod +x "$SCRIPT_INSTALL"
  fi
  cat > "$SCRIPT_LAUNCHER" <<'LAUNCH'
#!/usr/bin/env bash
exec bash /usr/local/sbin/snell.sh "$@"
LAUNCH
  chmod +x "$SCRIPT_LAUNCHER"
}

remote_script_version() {
  curl -fsSL "$SCRIPT_REMOTE_RAW" | grep -m1 '^SCRIPT_VERSION=' | sed 's/^SCRIPT_VERSION=//; s/"//g'
}

self_update() {
  require_pkg curl
  local remote; remote="$(remote_script_version || true)"
  if [ -z "${remote:-}" ]; then echo "获取远端脚本版本失败。"; return 1; fi
  echo "本地脚本版本：$SCRIPT_VERSION"
  echo "远端脚本版本：$remote"
  if version_gt "$remote" "$SCRIPT_VERSION"; then
    echo "发现新版本，正在更新脚本..."
    local tmp="/tmp/snell.sh.$$"
    curl -fsSL "$SCRIPT_REMOTE_RAW" -o "$tmp"
    grep -q '^SCRIPT_VERSION=' "$tmp" || { echo "远端脚本异常"; rm -f "$tmp"; return 1; }
    install -m 0755 "$tmp" "$SCRIPT_INSTALL"; rm -f "$tmp"
    exec bash "$SCRIPT_INSTALL"
  else
    echo "脚本已是最新版本。"
  fi
}

install_snell() {
  require_pkg wget unzip curl iproute2
  echo -e "${CYAN}获取 Snell 最新版本...${RESET}"
  LATEST="$(get_latest_version || true)"
  [ -z "${LATEST:-}" ] && { echo -e "${RED}❌ 无法获取 Snell 最新版本。${RESET}"; return 1; }
  echo -e "${YELLOW}最新版本：${LATEST}${RESET}"

  local URL; URL="$(get_download_url "$LATEST")"
  [ -z "$URL" ] && { echo -e "${RED}❌ 无法生成下载链接${RESET}"; return 1; }

  echo -e "${CYAN}下载 Snell 中...${RESET}"
  wget -O /tmp/snell.zip "$URL"
  unzip -o /tmp/snell.zip -d /tmp >/dev/null

  SN_SRC=$(find /tmp -type f -name "snell-server" | head -n1)
  if [ -z "$SN_SRC" ]; then
    echo -e "${RED}❌ 未在 /tmp 下找到 snell-server 文件${RESET}"
    unzip -l /tmp/snell.zip || true
    rm -f /tmp/snell.zip 2>/dev/null || true
    return 1
  fi

  install -m 0755 "$SN_SRC" "$SN_BIN"
  rm -f /tmp/snell.zip 2>/dev/null || true
  echo -e "${GREEN}✅ 已安装 snell-server 到 $SN_BIN${RESET}"

  ensure_user_and_dirs
  ensure_launcher

  mkdir -p "$SN_DIR"
  chown root:"$SN_USER" "$SN_DIR"
  chmod 750 "$SN_DIR"

  local def_port=8448
  if port_used_by_others "$def_port"; then
    def_port=$(random_unused_port)
    [ "$def_port" = 0 ] && def_port=8448
  fi
  local PASS; PASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)"

  cat > "$SN_CONFIG" <<EOF
[snell-server]
listen = ::0:${def_port}
psk = ${PASS}
ipv6 = true
EOF
  chown root:"$SN_USER" "$SN_CONFIG"
  chmod 640 "$SN_CONFIG"

  write_service
  restart_and_verify

  echo -e "\n${GREEN}✅ 安装完成${RESET}，监听端口：${def_port}，PSK：${PASS}"
  echo -e "现在起可直接输入：${YELLOW}snell${RESET} 进入管理菜单。\n"
  echo -e "${CYAN}—— 当前 Snell 配置 ——${RESET}"
  cat "$SN_CONFIG" || true
  echo "———————————————–"  
}

install_or_update_action() {
  require_pkg wget unzip curl iproute2
  if [ ! -x "$SN_BIN" ]; then
    install_snell
    return
  fi

  local current latest
  current="$(detect_installed_version || echo '')"
  latest="$(get_latest_version || true)"
  [ -z "$latest" ] && { echo "无法获取最新版本。"; return 1; }

  echo "当前版本：${current:-unknown}"
  echo "最新版本：$latest"

  if [ -z "$current" ] || [ "$current" = "unknown" ] || version_gt "$latest" "$current"; then
    echo "开始安装/升级到 $latest ..."
    local URL; URL="$(get_download_url "$latest")"
    wget -O /tmp/snell.zip "$URL"
    unzip -o /tmp/snell.zip -d /tmp >/dev/null
    local SN_SRC
    SN_SRC=$(find /tmp -type f -name "snell-server" | head -n1)
    if [ -n "$SN_SRC" ]; then
      install -m 0755 "$SN_SRC" "$SN_BIN"
      echo "✅ 完成 → $(detect_installed_version)"
    else
      echo -e "${RED}❌ 解压后未找到 snell-server，可用 unzip -l /tmp/snell.zip 查看内容${RESET}"
    fi
    rm -f /tmp/snell.zip 2>/dev/null || true
  else
    echo "已是最新版本，无需升级。"
  fi

  if [ -f "$SN_CONFIG" ]; then
    echo -e "${CYAN}当前 Snell 配置如下：${RESET}"
    cat "$SN_CONFIG"
  fi
  restart_and_verify
}

modify_config_action() {
  if [ ! -f "$SN_CONFIG" ]; then echo "未找到配置文件：$SN_CONFIG"; return; fi
  local old_port new_port cur_psk new_psk

  old_port=$(awk -F ':' '/^[[:space:]]*listen[[:space:]]*=/{print $NF}' "$SN_CONFIG" | tr -dc '0-9')
  cur_psk="$(awk -F '=' '/^[[:space:]]*psk[[:space:]]*=/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$SN_CONFIG")"

  echo -e "${YELLOW}当前监听端口：$old_port${RESET}"
  while true; do
    read -rp "输入新端口 [1024-65535，回车=不修改]：" new_port
    if [ -z "$new_port" ]; then
      new_port="$old_port"; break
    fi
    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
      if port_used_by_others "$new_port"; then
        echo -e "${RED}❌ 端口 $new_port 已被占用，请重试${RESET}"
        continue
      fi
      break
    else
      echo -e "${RED}❌ 端口必须在 1024-65535 范围内${RESET}"
    fi
  done

  echo -e "${YELLOW}当前密码(PSK)：${cur_psk:-<空>}${RESET}"
  while true; do
    read -rp "密码选项：1) 不修改（默认）  2) 随机生成  请输入 [1/2]：" sel
    sel="${sel:-1}"
    case "$sel" in
      1) new_psk="${cur_psk}"; [ -n "$new_psk" ] || new_psk="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)"; break ;;
      2) new_psk="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)"; break ;;
      *) echo "无效输入，请输入 1 或 2";;
    esac
  done

  cat > "$SN_CONFIG" <<EOF
[snell-server]
listen = ::0:${new_port}
psk = ${new_psk}
ipv6 = true
EOF

  chown root:"$SN_USER" "$SN_CONFIG"
  chmod 640 "$SN_CONFIG"
  restart_and_verify
  echo -e "${CYAN}修改后的配置如下：${RESET}"
  cat "$SN_CONFIG"
}

show_config_action() {
  if [ ! -f "$SN_CONFIG" ]; then echo "未找到配置文件：$SN_CONFIG"; return; fi
  echo "———————————————–"
  cat "$SN_CONFIG"
  echo "———————————————–"
}

uninstall_action() {
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SN_BIN" "$SERVICE_FILE"
  rm -rf "$SN_DIR" "$SN_STATE_DIR"
  if id -u "$SN_USER" >/dev/null 2>&1; then userdel "$SN_USER" 2>/dev/null || true; fi
  rm -f "$SCRIPT_INSTALL" "$SCRIPT_LAUNCHER"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
  echo -e "${GREEN}✅ 已卸载 Snell 和管理脚本。${RESET}"
}

main_self_heal() {
  if [ -x "$SN_BIN" ]; then
    ensure_user_and_dirs
    [ -f "$SN_CONFIG" ] || {
      echo -e "${YELLOW}发现缺失配置文件，自动补全...${RESET}"
      local def_port=8448
      if port_used_by_others "$def_port"; then
        def_port=$(random_unused_port)
        [ "$def_port" = 0 ] && def_port=8448
      fi
      local PASS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)"
      cat > "$SN_CONFIG" <<EOF
[snell-server]
listen = ::0:${def_port}
psk = ${PASS}
ipv6 = true
EOF
      chown root:"$SN_USER" "$SN_CONFIG"
      chmod 640 "$SN_CONFIG"
    }
    [ -f "$SERVICE_FILE" ] || {
      echo -e "${YELLOW}发现缺失 systemd 服务文件，自动补全...${RESET}"
      write_service
    }
  fi
}

need_root
ensure_launcher

while true; do
  main_self_heal
  clear
  show_header
  echo "1) 安装或更新 Snell"
  echo "2) 查看配置文件"
  echo "3) 修改配置"
  echo "4) 卸载 Snell"
  echo "5) 更新脚本"
  echo "0) 退出"
  echo "———————————————–"
  read -rp "请选择 [0-5]: " choice
  echo
  case "${choice:-}" in
    1) install_or_update_action; pause ;;
    2) show_config_action; pause ;;
    3) modify_config_action; pause ;;
    4) uninstall_action; pause ;;
    5) self_update; pause ;;
    0) echo "Bye"; exit 0 ;;
    *) echo "无效选项"; pause ;;
  esac
done
