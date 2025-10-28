#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.5.6"
SCRIPT_INSTALL="/usr/local/sbin/ssrust.sh"
SCRIPT_LAUNCHER="/usr/local/bin/ssrust"
SCRIPT_REMOTE_RAW="https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Scripts/ssrust.sh"

SS_USER="ssrust"
SS_DIR="/etc/ssrust"
SS_STATE_DIR="/var/lib/ssrust"
SS_CONFIG="$SS_DIR/config.json"
SS_BIN="/usr/local/bin/ssserver"
SERVICE_NAME="ssrust"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${RED}请用 root 运行${RESET}"; exit 1
  fi
}

require_pkg() {
  local pkgs=("$@") miss=()
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || miss+=("$p"); done
  if [ "${#miss[@]}" -gt 0 ]; then apt update && apt install -y "${miss[@]}"; fi
}

normalize_ver(){ echo "${1:-}" | sed 's/^v//'; }
version_gt(){ [ "$(printf '%s\n%s\n' "$(normalize_ver "$1")" "$(normalize_ver "$2")" | sort -V | tail -n1)" != "$(normalize_ver "$2")" ]; }

get_latest_version() {
  require_pkg curl jq
  curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
    | jq -r '.tag_name' 2>/dev/null
}

get_current_version() {
  if [ -x "$SS_BIN" ]; then "$SS_BIN" --version 2>/dev/null | awk '{print $2}' || true; fi
}

arch_triple() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "x86_64-unknown-linux-gnu" ;;
    aarch64|arm64)  echo "aarch64-unknown-linux-gnu" ;;
    armv7l|armv7)   echo "armv7-unknown-linux-gnueabihf" ;;
    i386|i686)      echo "i686-unknown-linux-gnu" ;;
    *) echo "unsupported" ;;
  esac
}

get_download_url() {
  local ver="$1" triple; triple="$(arch_triple)"
  [ "$triple" = "unsupported" ] && { echo >&2 -e "${RED}不支持的架构：$(uname -m)${RESET}"; return 1; }
  echo "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ver}/shadowsocks-${ver}.${triple}.tar.xz"
}

is_active() {
  if [ ! -x "$SS_BIN" ]; then
    echo "未安装"
  elif systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "运行中"
  else
    echo "未运行"
  fi
}

ensure_user_and_dirs() {
  id -u "$SS_USER" >/dev/null 2>&1 || useradd -r -M -d "$SS_STATE_DIR" -s /usr/sbin/nologin "$SS_USER"
  mkdir -p "$SS_STATE_DIR" "$SS_DIR"
  chown -R "$SS_USER:$SS_USER" "$SS_STATE_DIR"
  chown root:"$SS_USER" "$SS_DIR"
  chmod 750 "$SS_DIR"
}

write_service() {
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Shadowsocks-Rust Server
Documentation=https://github.com/shadowsocks/shadowsocks-rust
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
User=$SS_USER
Group=$SS_USER
Type=simple
UMask=0077
WorkingDirectory=$SS_STATE_DIR
ExecStart=$SS_BIN -c $SS_CONFIG
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
  local port="$1" pid_self; pid_self="$(get_main_pid || echo 0)"
  command -v ss >/dev/null 2>&1 || require_pkg iproute2
  local pids; pids="$(ss -lntupH 2>/dev/null | awk -v P=":$port" '$4 ~ P {print $NF}' \
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
  for _ in {1..50}; do
    port=$(shuf -i 1024-65535 -n1)
    if ! port_used_by_others "$port"; then echo "$port"; return 0; fi
  done
  echo 0
}

restart_and_verify() {
  systemctl daemon-reload || true
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  if ! systemctl restart "$SERVICE_NAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️ 服务重启失败，请查看： journalctl -u ${SERVICE_NAME} -e --no-pager${RESET}"
    return 0
  fi
  sleep 1
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo -e "${GREEN}✅ 服务已运行${RESET}"
  else
    echo -e "${YELLOW}⚠️ 服务未在运行，请查看： journalctl -u ${SERVICE_NAME} -e --no-pager${RESET}"
  fi
}

show_header() {
  local curver; curver="$(get_current_version || echo '-')" ; [ -z "$curver" ] && curver='-'
  local status; status="$(is_active)"
  echo "================================================"
  echo "  Shadowsocks-Rust 管理界面"
  echo "  状态：$status    已装版本：$curver"
  echo "  服务名：$SERVICE_NAME   二进制：$SS_BIN"
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
exec bash /usr/local/sbin/ssrust.sh "$@"
LAUNCH
  chmod +x "$SCRIPT_LAUNCHER"
}

remote_script_version() {
  curl -fsSL "$SCRIPT_REMOTE_RAW" | grep -m1 '^SCRIPT_VERSION=' | sed 's/^SCRIPT_VERSION=//; s/"//g'
}

self_update() {
  require_pkg curl
  local remote; remote="$(remote_script_version || true)"
  [ -z "${remote:-}" ] && { echo "获取远端脚本版本失败。"; return 1; }
  echo "本地脚本版本：$SCRIPT_VERSION"
  echo "远端脚本版本：$remote"
  if version_gt "$remote" "$SCRIPT_VERSION"; then
    echo "发现新版本，正在更新脚本..."
    local tmp="/tmp/ssrust.sh.$$"
    curl -fsSL "$SCRIPT_REMOTE_RAW" -o "$tmp"
    grep -q '^SCRIPT_VERSION=' "$tmp" || { echo "远端脚本异常"; rm -f "$tmp"; return 1; }
    install -m 0755 "$tmp" "$SCRIPT_INSTALL"; rm -f "$tmp"
    exec bash "$SCRIPT_INSTALL"
  else
    echo "脚本已是最新版本。"
  fi
}

prompt_method() {
  >&2 echo "请选择加密方式（会自动生成匹配长度的密码）："
  >&2 echo "  1) 2022-blake3-aes-128-gcm    (默认，16字节密钥)"
  >&2 echo "  2) 2022-blake3-aes-256-gcm    (32字节密钥)"
  >&2 echo "  3) 2022-blake3-chacha20-poly1305 (32字节密钥)"
  local sel choice
  while true; do
    read -rp "输入编号 [1-3]（回车默认1）: " sel
    sel="${sel:-1}"
    case "$sel" in
      1) choice="2022-blake3-aes-128-gcm" ;;
      2) choice="2022-blake3-aes-256-gcm" ;;
      3) choice="2022-blake3-chacha20-poly1305" ;;
      *) >&2 echo "无效编号，请重新输入 1-3。"; continue ;;
    esac
    echo "$choice"; return 0
  done
}

prompt_port() {
  local def="$1" input
  while true; do
    read -rp "新端口 (1024-65535，回车默认 $def): " input
    input="${input:-$def}"
    [[ "$input" =~ ^[0-9]+$ ]] || { echo "必须是数字。"; continue; }
    [ "$input" -ge 1024 ] && [ "$input" -le 65535 ] || { echo "仅允许 1024-65535。"; continue; }
    if port_used_by_others "$input"; then echo "端口 $input 已被占用，请重试。"; continue; fi
    echo "$input"; return
  done
}

gen_password_by_method() {
  local method="$1" n
  case "$method" in
    2022-blake3-aes-128-gcm) n=16 ;;   # 16 字节
    *) n=32 ;;                          # 其余 2022 算法 32 字节
  esac
  openssl rand -base64 "$n" | tr -d '\n'
}

json_get() {
  local key="$1"
  jq -r ".${key} // (.servers[0].${key})" "$SS_CONFIG"
}

install_ss() {
  require_pkg wget xz-utils tar openssl curl jq iproute2
  echo -e "${CYAN}获取最新版...${RESET}"
  LATEST="$(get_latest_version || true)"
  [ -z "${LATEST:-}" ] && { echo -e "${RED}获取最新版本失败（GitHub API）。${RESET}"; return 1; }
  echo -e "${YELLOW}最新版：$LATEST${RESET}"

  local url; url="$(get_download_url "$LATEST")" || return 1
  echo -e "${CYAN}下载并安装...${RESET}"
  local tmpdir; tmpdir="$(mktemp -d)"
  if ! wget -qO- "$url" | tar -xJ -C "$tmpdir"; then
    echo -e "${RED}下载或解压失败${RESET}"; rm -rf "$tmpdir"; return 1
  fi
  if [ ! -f "$tmpdir/ssserver" ]; then
    echo -e "${RED}未在解压目录找到 ssserver${RESET}"; ls -la "$tmpdir"; rm -rf "$tmpdir"; return 1
  fi
  install -m 0755 "$tmpdir/ssserver" "$SS_BIN"
  rm -rf "$tmpdir"
  echo -e "${GREEN}✅ 已安装 ssserver 到 $SS_BIN${RESET}"

  ensure_user_and_dirs
  ensure_launcher

  if [ ! -f "$SS_CONFIG" ]; then
    local def_port=8443
    if port_used_by_others "$def_port"; then
      def_port=$(random_unused_port)
      [ "$def_port" = 0 ] && def_port=8443
    fi
    local PASS; PASS="$(openssl rand -base64 16 | tr -d '\n')"
    cat > "$SS_CONFIG" <<EOF
{
  "server": "::",
  "server_port": $def_port,
  "method": "2022-blake3-aes-128-gcm",
  "password": "$PASS",
  "mode": "tcp_and_udp",
  "timeout": 300
}
EOF
    chown root:"$SS_USER" "$SS_CONFIG"; chmod 640 "$SS_CONFIG"
    echo -e "${GREEN}默认配置已生成：端口 $def_port，方法 2022-blake3-aes-128-gcm${RESET}"
  fi

  write_service
  restart_and_verify

  echo -e "当前状态：$(is_active)"
  echo -e "现在起可直接输入：${YELLOW}ssrust${RESET} 进入管理菜单。"
}

install_or_update_action() {
  require_pkg wget xz-utils tar openssl curl jq iproute2
  if [ ! -x "$SS_BIN" ]; then
    install_ss; return
  fi
  local current latest
  current="$(get_current_version || echo '')"
  latest="$(get_latest_version || true)"
  [ -z "$latest" ] && { echo "无法获取最新版本。"; return 1; }
  echo "当前版本：${current:-unknown}"
  echo "最新版本：$latest"
  if [ -n "$current" ] && ! version_gt "$latest" "$current"; then
    echo "已是最新版本，无需升级。"
  else
    echo "发现新版本，开始升级..."
    local url; url="$(get_download_url "$latest")" || return 1
    local tmpdir; tmpdir="$(mktemp -d)"
    if ! wget -qO- "$url" | tar -xJ -C "$tmpdir"; then
      echo -e "${RED}下载或解压失败${RESET}"; rm -rf "$tmpdir"; return 1
    fi
    if [ ! -f "$tmpdir/ssserver" ]; then
      echo -e "${RED}未在解压目录找到 ssserver${RESET}"; ls -la "$tmpdir"; rm -rf "$tmpdir"; return 1
    fi
    install -m 0755 "$tmpdir/ssserver" "$SS_BIN"
    rm -rf "$tmpdir"
    echo "✅ 升级完成 → $(get_current_version || echo unknown)"
  fi
  if [ -f "$SS_CONFIG" ]; then
    echo -e "${CYAN}当前配置：${RESET}"
    cat "$SS_CONFIG"
  fi
  restart_and_verify
}

show_config_action() {
  if [ ! -f "$SS_CONFIG" ]; then echo "未找到配置文件：$SS_CONFIG"; return; fi
  require_pkg jq
  local PORT PASS METHOD
  PORT=$(json_get "server_port")
  PASS=$(json_get "password")
  METHOD=$(json_get "method")
  echo "-----------------------------------------------"
  echo "端口:   $PORT"
  echo "密码:   $PASS"
  echo "加密:   $METHOD"
  echo "-----------------------------------------------"
  echo "原始 JSON："
  cat "$SS_CONFIG"
}

edit_config_action() {
  if [ ! -f "$SS_CONFIG" ]; then echo "未找到配置文件：$SS_CONFIG"; return; fi
  require_pkg jq openssl iproute2

  local cur_port cur_pass cur_method
  cur_port=$(json_get "server_port")
  cur_pass=$(json_get "password")
  cur_method=$(json_get "method")

  local def_for_prompt="${cur_port:-8443}"
  local new_port; new_port="$(prompt_port "$def_for_prompt")"

  echo "当前加密方式: ${cur_method:-未知}"
  local new_method; new_method="$(prompt_method)"
  
  local req_bytes=32
  [ "$new_method" = "2022-blake3-aes-128-gcm" ] && req_bytes=16

  local decoded_len
  decoded_len=$(printf '%s' "${cur_pass:-}" | base64 -d 2>/dev/null | wc -c | tr -d ' ') || decoded_len=0

  echo "当前密码: ${cur_pass:-<空>}"
  read -rp "密码选项：1) 不修改（默认）  2) 随机生成  请输入 [1/2]：" pass_sel
  pass_sel="${pass_sel:-1}"

  local new_pass="$cur_pass"
  if [ "$pass_sel" = "2" ]; then
    new_pass="$(gen_password_by_method "$new_method")"
    echo "已随机生成新密码。"
  else
    if [ -z "${new_pass:-}" ] || [ "$decoded_len" -ne "$req_bytes" ]; then
      new_pass="$(gen_password_by_method "$new_method")"
      echo "原密码与新加密方式不匹配，已自动生成随机密码。"
    fi
  fi

  cat > "$SS_CONFIG" <<EOF
{
  "server": "::",
  "server_port": $new_port,
  "method": "$new_method",
  "password": "$new_pass",
  "mode": "tcp_and_udp",
  "timeout": 300
}
EOF
  chown root:"$SS_USER" "$SS_CONFIG"; chmod 640 "$SS_CONFIG"

  echo "配置已更新，正在重启服务..."
  restart_and_verify
  echo -e "${CYAN}修改后的配置如下：${RESET}"
  cat "$SS_CONFIG"
}

uninstall_action() {
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SS_BIN" "$SERVICE_FILE"
  rm -rf "$SS_DIR" "$SS_STATE_DIR"
  if id -u "$SS_USER" >/dev/null 2>&1; then userdel "$SS_USER" 2>/dev/null || true; fi
  rm -f "$SCRIPT_INSTALL" "$SCRIPT_LAUNCHER"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
  echo -e "${GREEN}✅ 已卸载 Shadowsocks-Rust 和管理脚本。${RESET}"
}

main_self_heal() {
  if [ -x "$SS_BIN" ]; then
    ensure_user_and_dirs
    [ -f "$SS_CONFIG" ] || {
      echo -e "${YELLOW}发现缺失配置文件，自动补全...${RESET}"
      local def_port=8443
      if port_used_by_others "$def_port"; then
        def_port=$(random_unused_port)
        [ "$def_port" = 0 ] && def_port=8443
      fi
      local PASS; PASS="$(openssl rand -base64 16 | tr -d '\n')"
      cat > "$SS_CONFIG" <<EOF
{
  "server": "::",
  "server_port": $def_port,
  "method": "2022-blake3-aes-128-gcm",
  "password": "$PASS",
  "mode": "tcp_and_udp",
  "timeout": 300
}
EOF
      chown root:"$SS_USER" "$SS_CONFIG"; chmod 640 "$SS_CONFIG"
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
  echo "1) 安装或更新 SSRust"
  echo "2) 查看配置文件"
  echo "3) 修改配置"
  echo "4) 卸载 SSRust"
  echo "5) 更新脚本"
  echo "0) 退出"
  echo "-----------------------------------------------"
  read -rp "请选择 [0-5]: " choice
  echo
  case "${choice:-}" in
    1) install_or_update_action; pause ;;
    2) show_config_action;       pause ;;
    3) edit_config_action;       pause ;;
    4) uninstall_action;         pause ;;
    5) self_update;              pause ;;
    0) echo "Bye"; exit 0 ;;
    *) echo "无效选项"; pause ;;
  esac
done
