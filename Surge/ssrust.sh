#!/usr/bin/env bash
set -Eeuo pipefail

SS_USER="ssrust"
SS_DIR="/etc/ssrust"
SS_CONFIG="$SS_DIR/config.json"
SS_BIN="/usr/local/bin/ssserver"
SERVICE_FILE="/etc/systemd/system/ssrust.service"

#---------------- helpers ----------------
need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行：sudo $0"; exit 1
  fi
}

require_pkg() {
  # 用于按需安装依赖
  local pkgs=("$@")
  local miss=()
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || miss+=("$p")
  done
  if [ "${#miss[@]}" -gt 0 ]; then
    apt update && apt install -y "${miss[@]}"
  fi
}

get_latest_version() {
  # 返回形如 v1.23.5
  curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
   | grep '"tag_name"' | head -n1 | cut -d '"' -f4
}

get_current_version() {
  if [ -x "$SS_BIN" ]; then
    "$SS_BIN" --version 2>/dev/null | awk '{print $2}' || true
  fi
}

normalize_ver() {
  # 去掉前缀 v
  echo "$1" | sed 's/^v//'
}

version_gt() {
  # 返回 0 表示 $1 > $2
  # 使用 sort -V 做语义化比较
  [ "$(printf '%s\n%s\n' "$(normalize_ver "$1")" "$(normalize_ver "$2")" | sort -V | tail -n1)" != "$(normalize_ver "$2")" ]
}

is_active() {
  systemctl is-active --quiet ssrust && echo "运行中" || echo "未运行"
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

show_header() {
  local curver; curver="$(get_current_version || echo '-')" ; [ -z "$curver" ] && curver='-'
  local status; status="$(is_active)"
  echo "==============================================="
  echo "  Shadowsocks-Rust 管理界面"
  echo "  状态：$status    已装版本：$curver"
  echo "  服务名：ssrust    二进制：$SS_BIN"
  echo "==============================================="
}

pause() { echo; read -rp "按回车键返回菜单..." _; }

#---------------- actions ----------------
install_action() {
  if [ -x "$SS_BIN" ]; then
    echo "检测到已安装（版本：$(get_current_version || echo '-')）。如需升级请选择菜单 2。"
    return
  fi

  require_pkg wget xz-utils openssl curl jq
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

  if [ ! -f "$SS_CONFIG" ]; then
    local PASS; PASS="$(openssl rand -base64 16)"
    cat > "$SS_CONFIG" <<EOF
{
  "server": "[::]",
  "server_port": 2048,
  "password": "$PASS",
  "method": "2022-blake3-aes-128-gcm",
  "mode": "tcp_and_udp",
  "timeout": 300
}
EOF
    chown "$SS_USER:$SS_USER" "$SS_CONFIG"
    chmod 640 "$SS_CONFIG"
    echo "已生成默认配置：端口 2048，加密 2022-blake3-aes-128-gcm"
  fi

  write_service
  systemctl daemon-reload
  systemctl enable --now ssrust

  echo "安装完成，服务已启动。当前状态：$(is_active)"
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
    systemctl daemon-reload
    systemctl restart ssrust
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
  # 兼容单实例与 servers 数组两种格式
  local PORT PASS METHOD
  PORT=$(jq -r '.server_port // (.servers[0].server_port)' "$SS_CONFIG")
  PASS=$(jq -r '.password // (.servers[0].password)' "$SS_CONFIG")
  METHOD=$(jq -r '.method // (.servers[0].method)' "$SS_CONFIG")
  echo "-----------------------------------------------"
  echo "端口:   $PORT"
  echo "密码:   $PASS"
  echo "加密:   $METHOD"
  echo "-----------------------------------------------"
  echo "原始 JSON："
  cat "$SS_CONFIG"
}

edit_config_action() {
  if [ ! -f "$SS_CONFIG" ]; then
    echo "未找到配置文件：$SS_CONFIG"; return
  fi
  require_pkg jq openssl
  local cur_port cur_pass cur_method
  cur_port=$(jq -r '.server_port // (.servers[0].server_port)' "$SS_CONFIG")
  cur_pass=$(jq -r '.password // (.servers[0].password)' "$SS_CONFIG")
  cur_method=$(jq -r '.method // (.servers[0].method)' "$SS_CONFIG")

  read -rp "新端口 (回车保持 $cur_port): " new_port
  [ -z "${new_port:-}" ] && new_port="$cur_port"
  read -rp "新密码 (回车保持不变，输入空格生成随机): " new_pass
  if [ "${new_pass:-}" = " " ]; then new_pass="$(openssl rand -base64 16)"; elif [ -z "${new_pass:-}" ]; then new_pass="$cur_pass"; fi
  echo "常用加密: 2022-blake3-aes-128-gcm / 2022-blake3-aes-256-gcm"
  read -rp "新加密 (回车保持 $cur_method): " new_method
  [ -z "${new_method:-}" ] && new_method="$cur_method"

  cat > "$SS_CONFIG" <<EOF
{
  "server": "[::]",
  "server_port": $new_port,
  "password": "$new_pass",
  "method": "$new_method",
  "mode": "tcp_and_udp",
  "timeout": 300
}
EOF
  chown "$SS_USER:$SS_USER" "$SS_CONFIG"
  chmod 640 "$SS_CONFIG"
  systemctl restart ssrust
  echo "配置已更新并重启。当前状态：$(is_active)"
}

uninstall_action() {
  systemctl stop ssrust 2>/dev/null || true
  systemctl disable ssrust 2>/dev/null || true
  rm -f "$SS_BIN" "$SERVICE_FILE"
  rm -rf "$SS_DIR"
  id -u "$SS_USER" >/dev/null 2>&1 && userdel -r "$SS_USER" || true
  systemctl daemon-reload
  echo "已卸载。"
}

#---------------- main menu ----------------
need_root
while true; do
  clear
  show_header
  echo "1) 安装（装完即运行）"
  echo "2) 升级（仅新版本才替换并重启）"
  echo "3) 查看配置"
  echo "4) 修改配置"
  echo "5) 卸载"
  echo "0) 退出"
  echo "-----------------------------------------------"
  read -rp "请选择 [0-5]: " choice
  echo
  case "${choice:-}" in
    1) install_action; pause ;;
    2) upgrade_action; pause ;;
    3) show_config_action; pause ;;
    4) edit_config_action; pause ;;
    5) uninstall_action; pause ;;
    0) echo "Bye"; exit 0 ;;
    *) echo "无效选项"; pause ;;
  esac
done
