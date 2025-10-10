#!/usr/bin/env bash
set -Eeuo pipefail

#================= 脚本元信息（用于自升级） =================
SCRIPT_VERSION="1.4.3"
SCRIPT_INSTALL="/usr/local/sbin/ssrust.sh"
SCRIPT_LAUNCHER="/usr/local/bin/ssrust"
SCRIPT_REMOTE_RAW="https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/ssrust.sh"

#================= ss-rust 基本配置 =================
SS_USER="ssrust"
SS_DIR="/etc/ssrust"
SS_CONFIG="$SS_DIR/config.json"
SS_BIN="/usr/local/bin/ssserver"
SERVICE_NAME="ssrust"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

#---------------- helpers ----------------
need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行：sudo $0"; exit 1
  fi
}

require_pkg() {
  local pkgs=("$@") miss=()
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || miss+=("$p"); done
  if [ "${#miss[@]}" -gt 0 ]; then apt update && apt install -y "${miss[@]}"; fi
}

get_latest_version() {
  curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
   | grep '"tag_name"' | head -n1 | cut -d '"' -f4
}

get_current_version() {
  if [ -x "$SS_BIN" ]; then
    "$SS_BIN" --version 2>/dev/null | awk '{print $2}' || true
  fi
}

normalize_ver(){ echo "$1" | sed 's/^v//'; }
version_gt(){
  [ "$(printf '%s\n%s\n' "$(normalize_ver "$1")" "$(normalize_ver "$2")" | sort -V | tail -n1)" != "$(normalize_ver "$2")" ]
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
  id -u "$SS_USER" >/dev/null 2>&1 || useradd -r -M -d "$SS_DIR" -s /usr/sbin/nologin "$SS_USER"
  mkdir -p "$SS_DIR"
  chown -R "$SS_USER:$SS_USER" "$SS_DIR"
}

write_service() {
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Shadowsocks-Rust Server
Documentation=https://github.com/shadowsocks/shadowsocks-rust
After=network-online.target nss-lookup.target

[Service]
Type=simple
ExecStart=$SS_BIN --config $SS_CONFIG
WorkingDirectory=$SS_DIR
User=$SS_USER
Group=$SS_USER
UMask=0077

NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

get_main_pid() {
  systemctl show -p MainPID "$SERVICE_NAME" 2>/dev/null | cut -d= -f2
}

port_used_by_others() {
  local port="$1"
  local pid_self; pid_self="$(get_main_pid || echo 0)"
  if ! command -v ss >/dev/null 2>&1; then require_pkg iproute2; fi
  local pids
  pids="$(ss -lntupH 2>/dev/null | awk -v P=":$port" '$4 ~ P {print $NF}' | sed 's/[^0-9]/\n/g' | grep -E '^[0-9]+$' || true)"
  if [ -z "$pids" ]; then return 1; fi
  while read -r p; do
    [ -z "$p" ] && continue
    if [ "$p" != "$pid_self" ] && [ "$p" != "0" ]; then return 0; fi
  done <<< "$pids"
  return 1
}

prompt_method() {
  >&2 echo "请选择加密方式（将随机生成对应长度的密码）："
  >&2 echo "  1) 2022-blake3-aes-128-gcm    (默认，16字节密钥)"
  >&2 echo "  2) 2022-blake3-aes-256-gcm    (32字节密钥)"
  >&2 echo "  3) 2022-blake3-chacha20-poly1305 (32字节密钥)"
  >&2 echo "  4) 2022-blake3-chacha8-poly1305  (32字节密钥)"

  local sel choice
  while true; do
    read -rp "输入编号 [1-4]（回车默认1）: " sel
    sel="${sel:-1}"
    case "$sel" in
      1) choice="2022-blake3-aes-128-gcm" ;;
      2) choice="2022-blake3-aes-256-gcm" ;;
      3) choice="2022-blake3-chacha20-poly1305" ;;
      4) choice="2022-blake3-chacha8-poly1305" ;;
      *) >&2 echo "无效编号，请重新输入 1-4。"; continue ;;
    esac
    echo "$choice"
    return 0
  done
}

prompt_port() {
  local def="$1" input
  while true; do
    read -rp "新端口 (1024-65535，回车默认 $def): " input
    input="${input:-$def}"
    if ! [[ "$input" =~ ^[0-9]+$ ]]; then >&2 echo "必须是数字。"; continue; fi
    if [ "$input" -lt 1024 ] || [ "$input" -gt 65535 ]; then >&2 echo "仅允许 1024-65535。"; continue; fi
    if port_used_by_others "$input"; then >&2 echo "端口 $input 已被占用，请重试。"; continue; fi
    echo "$input"; return
  done
}

gen_password_by_method() {
  local method="$1" n
  case "$method" in
    2022-blake3-aes-128-gcm) n=16 ;;   # 需要 16 字节
    *) n=32 ;;                          # 其余 2022 算法需要 32 字节
  esac
  # 生成 n 字节随机密钥，并用 Base64 表示（去掉换行）
  openssl rand -base64 "$n" | tr -d '\n'
}

json_get() {
  local key="$1"
  jq -r ".${key} // (.servers[0].${key})" "$SS_CONFIG"
}

restart_and_verify() {
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME" 2>/dev/null || systemctl start "$SERVICE_NAME" 2>/dev/null || true
  sleep 1
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "服务已运行。"
  else
    echo "⚠️ 服务未能启动，请检查配置。"
    echo "   查看日志: journalctl -u ${SERVICE_NAME} -e --no-pager"
    return 1
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
  if [[ "$self" == /proc/*/fd/* ]]; then
    curl -fsSL "$SCRIPT_REMOTE_RAW" -o "$SCRIPT_INSTALL"
    chmod +x "$SCRIPT_INSTALL"
  else
    if [ "$self" != "$SCRIPT_INSTALL" ]; then cp -f "$self" "$SCRIPT_INSTALL"; fi
    chmod +x "$SCRIPT_INSTALL"
  fi
  cat > "$SCRIPT_LAUNCHER" <<'LAUNCH'
#!/usr/bin/env bash
exec bash /usr/local/sbin/ssrust.sh
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
    local tmp="/tmp/ssrust.sh.$$"
    curl -fsSL "$SCRIPT_REMOTE_RAW" -o "$tmp"
    grep -q '^SCRIPT_VERSION=' "$tmp" || { echo "远端脚本异常"; rm -f "$tmp"; return 1; }
    install -m 0755 "$tmp" "$SCRIPT_INSTALL"; rm -f "$tmp"
    exec bash "$SCRIPT_INSTALL"
  else
    echo "脚本已是最新版本。"
  fi
}

#---------------- actions ----------------
install_action() {
  if [ -x "$SS_BIN" ]; then
    echo "检测到已安装（版本：$(get_current_version || echo '-')）。如需升级请选择菜单 2。"
    return
  fi

  require_pkg wget xz-utils openssl curl jq iproute2
  echo "获取最新版..."
  LATEST="$(get_latest_version || true)"
  [ -z "${LATEST:-}" ] && { echo "获取最新版本失败（GitHub API）。"; return 1; }
  echo "最新版：$LATEST"

  echo "下载并安装..."
  wget -qO- "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST}/shadowsocks-${LATEST}.x86_64-unknown-linux-gnu.tar.xz" \
   | tar -xJ -C /tmp
  mv /tmp/ssserver "$SS_BIN"
  chmod +x "$SS_BIN"

  ensure_user_and_dirs
  ensure_launcher

  if [ ! -f "$SS_CONFIG" ]; then
    local PASS; PASS="$(openssl rand -base64 16 | tr -d '\n')"
    # 默认端口 2048，如被占用则找一个空闲端口
    local def_port=2048
    if port_used_by_others "$def_port"; then
      def_port=$(shuf -i 20000-29999 -n1)
    fi
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
    chown "$SS_USER:$SS_USER" "$SS_CONFIG"
    chmod 640 "$SS_CONFIG"
    echo "已生成默认配置：端口 $def_port，加密 2022-blake3-aes-128-gcm"
  fi

  write_service
  systemctl daemon-reload
  restart_and_verify

  echo "安装完成，服务当前状态：$(is_active)"
  echo "现在起可直接输入：ssrust 进入管理菜单。"
}

upgrade_action() {
  if [ ! -x "$SS_BIN" ]; then
    echo "尚未安装，先执行菜单 1 安装。"; return
  fi
  require_pkg wget xz-utils curl
  local current latest
  current="$(get_current_version || echo '')"
  [ -z "$current" ] && { echo "无法获取已装版本。"; return 1; }
  latest="$(get_latest_version || true)"
  [ -z "$latest" ] && { echo "获取最新版本失败（GitHub API）。"; return 1; }

  echo "当前版本：$current"
  echo "最新版本：$latest"
  if version_gt "$latest" "$current"; then
    echo "发现新版本，开始升级..."
    wget -qO- "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest}/shadowsocks-${latest}.x86_64-unknown-linux-gnu.tar.xz" \
     | tar -xJ -C /tmp
    mv /tmp/ssserver "$SS_BIN"
    chmod +x "$SS_BIN"
    restart_and_verify || true
    echo "升级完成 → $(get_current_version)"
  else
    echo "已是最新版本，无需升级。"
  fi
}

show_config_action() {
  if [ ! -f "$SS_CONFIG" ]; then
    echo "未找到配置文件：$SS_CONFIG"; return
  fi
  require_pkg jq
  echo "配置文件：$SS_CONFIG"
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

  local def_for_prompt="${cur_port:-2048}"
  local new_port; new_port="$(prompt_port "$def_for_prompt")"

  echo "当前加密方式: $cur_method"
  local new_method; new_method="$(prompt_method)"

  local new_pass="$cur_pass"
  if [ "$new_method" != "$cur_method" ]; then
    new_pass="$(gen_password_by_method "$new_method")"
    echo "已为新加密方式生成随机密码。"
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
  chown "$SS_USER:$SS_USER" "$SS_CONFIG"; chmod 640 "$SS_CONFIG"

  echo "配置已更新，正在重启服务..."
  restart_and_verify
}

uninstall_action() {
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SS_BIN" "$SERVICE_FILE"
  rm -rf "$SS_DIR"
  # 删除用户（忽略找不到 home/mail 的提示）
  if id -u "$SS_USER" >/dev/null 2>&1; then
    userdel "$SS_USER" 2>/dev/null || true
  fi
  # 删除脚本和启动器
  rm -f "$SCRIPT_INSTALL" "$SCRIPT_LAUNCHER"
  systemctl daemon-reload
  echo "✅ 已卸载 ss-rust 和管理脚本。"
}

#---------------- main ----------------
need_root
ensure_launcher

while true; do
  clear
  show_header
  echo "1) 安装（装完即运行）"
  echo "2) 升级（仅新版本才替换并重启）"
  echo "3) 修改配置"
  echo "4) 查看配置"
  echo "5) 卸载"
  echo "6) 升级脚本（从GitHub拉取新版本）"
  echo "0) 退出"
  echo "-----------------------------------------------"
  read -rp "请选择 [0-6]: " choice
  echo
  case "${choice:-}" in
    1) install_action; pause ;;
    2) upgrade_action; pause ;;
    3) edit_config_action; pause ;;
    4) show_config_action; pause ;;
    5) uninstall_action; pause ;;
    6) self_update; pause ;;
    0) echo "Bye"; exit 0 ;;
    *) echo "无效选项"; pause ;;
  esac
done
