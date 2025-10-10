#!/usr/bin/env bash
set -Eeuo pipefail

#==================== 元数据（脚本自更新用） ====================
SCRIPT_VERSION="1.2.0"
SCRIPT_URL="https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/ssrust.sh"
# 尝试 realpath，不存在则 readlink -f
SCRIPT_PATH="$( (command -v realpath >/dev/null 2>&1 && realpath "$0") || readlink -f "$0" )"

#==================== 基本参数 ====================
SS_USER="ssrust"
SS_DIR="/etc/ssrust"
SS_CONFIG="$SS_DIR/config.json"
SS_BIN="/usr/local/bin/ssserver"
SERVICE_FILE="/etc/systemd/system/ssrust.service"
INSTALL_SHORTCUT="yes"                # yes: 安装/首次运行时创建 /usr/local/bin/ssrust 快捷入口
SHORTCUT_PATH="/usr/local/bin/ssrust"

# 常见加密方式（编号菜单）
CIPHERS=(
  "2022-blake3-aes-128-gcm"
  "2022-blake3-aes-256-gcm"
  "2022-blake3-chacha20-poly1305"
  "2022-blake3-chacha8-poly1305"
)

#==================== 通用工具函数 ====================
need_root(){ if [ "${EUID:-$(id -u)}" -ne 0 ]; then echo "请用 root 运行：sudo $0"; exit 1; fi; }

require_pkg() {
  local miss=()
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || miss+=("$p"); done
  if [ "${#miss[@]}" -gt 0 ]; then
    apt update && apt install -y "${miss[@]}"
  fi
}

# 架构映射：返回 release 资源名里的三段目标串
detect_target_triple() {
  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  echo "x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
    *)
      echo "不支持的架构：$arch" >&2
      return 1
      ;;
  esac
}

get_latest_tag() {
  # e.g. v1.23.6
  curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
    | grep -m1 '"tag_name"' | cut -d '"' -f4
}

get_current_version() {
  if [ -x "$SS_BIN" ]; then
    "$SS_BIN" --version 2>/dev/null | awk '{print $2}'
  else
    echo "-"
  fi
}

normalize_ver(){ echo "$1" | sed 's/^v//'; }

version_gt() {
  # return 0 if $1 > $2
  local a b
  a="$(normalize_ver "$1")"; b="$(normalize_ver "$2")"
  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" != "$b" ]
}

is_active(){ systemctl is-active --quiet ssrust && echo "运行中" || echo "未运行"; }

port_in_use() {
  # 使用 ss 读取本地监听，判断是否存在以 :PORT 结尾的目标
  local p="$1"
  ss -tuln | awk '{print $5}' | grep -Eq "[:.]${p}$"
}

rand_base64() { openssl rand -base64 "${1:-16}"; }

#==================== systemd / 用户 / 配置 ====================
ensure_user_dirs() {
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

ensure_shortcut() {
  [ "$INSTALL_SHORTCUT" != "yes" ] && return 0
  if [ ! -e "$SHORTCUT_PATH" ]; then
    ln -sf "$SCRIPT_PATH" "$SHORTCUT_PATH"
    chmod +x "$SHORTCUT_PATH"
  fi
}

#==================== 下载 / 安装 / 升级 二进制 ====================
download_and_install_bin() {
  local tag="$1"
  local triple; triple="$(detect_target_triple)" || return 1
  local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${tag}/shadowsocks-${tag}.${triple}.tar.xz"

  echo ">>> 下载二进制：$url"
  require_pkg wget xz-utils
  rm -f /tmp/ssserver 2>/dev/null || true
  wget -qO- "$url" | tar -xJ -C /tmp
  if [ ! -f /tmp/ssserver ]; then
    echo "解包未找到 /tmp/ssserver，可能上游包结构变化或下载失败"; return 1
  fi
  mv /tmp/ssserver "$SS_BIN"
  chmod +x "$SS_BIN"
}

#==================== 视图 / UI ====================
show_header() {
  echo "===================================================="
  echo "  Shadowsocks-Rust 管理界面"
  echo "  状态：$(is_active)    已装版本：$(get_current_version)"
  echo "  脚本版本：$SCRIPT_VERSION"
  echo "  服务名：ssrust        二进制：$SS_BIN"
  echo "===================================================="
}

pause() { echo; read -rp "按回车返回菜单..." _; }

#==================== 具体操作 ====================
install_action() {
  if [ -x "$SS_BIN" ]; then
    echo "检测到已安装（版本：$(get_current_version)）。如需升级请选择菜单 2。"
    return 0
  fi

  require_pkg curl jq openssl
  local tag; tag="$(get_latest_tag)"
  [ -z "$tag" ] && { echo "获取最新版本失败（GitHub API）"; return 1; }

  download_and_install_bin "$tag" || return 1
  ensure_user_dirs

  if [ ! -f "$SS_CONFIG" ]; then
    local pass; pass="$(rand_base64 16)"
    cat > "$SS_CONFIG" <<EOF
{
  "server": "[::]",
  "server_port": 2048,
  "password": "$pass",
  "method": "2022-blake3-aes-128-gcm",
  "mode": "tcp_and_udp",
  "timeout": 300
}
EOF
    chown "$SS_USER:$SS_USER" "$SS_CONFIG"
    chmod 640 "$SS_CONFIG"
    echo ">>> 已写入默认配置（端口 2048，加密 2022-blake3-aes-128-gcm）"
  fi

  write_service
  systemctl daemon-reload
  systemctl enable --now ssrust
  ensure_shortcut

  echo "安装完成。当前状态：$(is_active)"
}

upgrade_action() {
  if [ ! -x "$SS_BIN" ]; then
    echo "尚未安装，请先执行 1 安装。"
    return 1
  fi

  require_pkg curl
  local cur latest
  cur="$(get_current_version)"
  latest="$(get_latest_tag)"
  [ -z "$latest" ] && { echo "获取最新版本失败（GitHub API）"; return 1; }

  echo "当前版本：$cur"
  echo "最新版本：$latest"

  if version_gt "$latest" "$cur"; then
    echo "发现新版本，开始升级..."
    download_and_install_bin "$latest" || return 1
    systemctl daemon-reload
    systemctl restart ssrust || systemctl start ssrust
    echo "升级完成 → $(get_current_version)"
  else
    echo "已是最新版本，无需升级。"
  fi
}

config_edit_action() {
  if [ ! -f "$SS_CONFIG" ]; then
    echo "未找到配置文件：$SS_CONFIG"; return 1
  fi
  require_pkg jq openssl

  local cur_port cur_pass cur_method
  cur_port="$(jq -r '.server_port' "$SS_CONFIG")"
  cur_pass="$(jq -r '.password' "$SS_CONFIG")"
  cur_method="$(jq -r '.method' "$SS_CONFIG")"

  # 端口：范围检查 + 占用检查
  local new_port
  while true; do
    read -rp "新端口 (1024-65535, 回车保持 $cur_port): " new_port
    [ -z "${new_port:-}" ] && new_port="$cur_port"
    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
      if port_in_use "$new_port"; then
        echo "端口 $new_port 已被占用，请重新输入。"
        continue
      fi
      break
    else
      echo "端口不合法，请输入 1024–65535 的整数。"
    fi
  done

  # 密码：保持 / 随机 / 自定义
  local new_pass
  read -rp "新密码 (回车保持原值，输入单个空格生成随机): " new_pass
  if [ "${new_pass:-}" = " " ]; then
    new_pass="$(rand_base64 16)"
  elif [ -z "${new_pass:-}" ]; then
    new_pass="$cur_pass"
  fi

  # 加密方式：编号选择 / 回车保持
  echo "可选加密方式："
  local i=1
  for c in "${CIPHERS[@]}"; do
    echo "  $i) $c"
    i=$((i+1))
  done
  local choice new_method
  read -rp "选择加密编号 (回车保持 $cur_method): " choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#CIPHERS[@]}" ]; then
    new_method="${CIPHERS[$((choice-1))]}"
  else
    new_method="$cur_method"
  fi

  # 写入配置
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

  # 重启并确保服务运行
  systemctl restart ssrust || systemctl start ssrust
  echo "配置已更新 → 端口:$new_port  加密:$new_method  状态:$(is_active)"
}

show_config_action() {
  if [ ! -f "$SS_CONFIG" ]; then
    echo "未找到配置文件：$SS_CONFIG"
    return 1
  fi
  require_pkg jq
  echo "配置文件路径：$SS_CONFIG"
  echo "---------------- JSON ----------------"
  jq . "$SS_CONFIG"
  echo "--------------------------------------"
}

uninstall_action() {
  systemctl stop ssrust 2>/dev/null || true
  systemctl disable ssrust 2>/dev/null || true
  rm -f "$SS_BIN" "$SERVICE_FILE"
  rm -rf "$SS_DIR"
  id -u "$SS_USER" >/dev/null 2>&1 && userdel -r "$SS_USER" || true
  systemctl daemon-reload
  echo "已卸载 Shadowsocks-Rust。"
}

#==================== 脚本自更新 ====================
self_update_action() {
  echo "检查远程脚本版本..."
  local remote_ver
  remote_ver="$(curl -fsSL "$SCRIPT_URL" | grep -m1 '^SCRIPT_VERSION=' | cut -d '"' -f2)"
  if [ -z "$remote_ver" ]; then
    echo "获取远程版本失败（检查链接或网络）"
    return 1
  fi
  echo "当前脚本：$SCRIPT_VERSION"
  echo "远程脚本：$remote_ver"
  if version_gt "$remote_ver" "$SCRIPT_VERSION"; then
    echo "发现新版本，开始更新..."
    curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "脚本已更新到 $remote_ver"
    echo "请重新运行：$SCRIPT_PATH  或直接输入：ssrust"
    exit 0
  else
    echo "脚本已是最新版本。"
  fi
}

#==================== 主菜单 ====================
need_root
while true; do
  clear
  show_header
  echo "1) 安装（装完即运行）"
  echo "2) 升级（仅新版本才替换并重启）"
  echo "3) 修改配置"
  echo "4) 查看配置"
  echo "5) 卸载"
  echo "6) 升级脚本"
  echo "0) 退出"
  echo "----------------------------------------------------"
  read -rp "请选择 [0-6]: " choice
  echo
  case "${choice:-}" in
    1) install_action; pause ;;
    2) upgrade_action; pause ;;
    3) config_edit_action; pause ;;
    4) show_config_action; pause ;;
    5) uninstall_action; pause ;;
    6) self_update_action; pause ;;
    0) echo "Bye"; exit 0 ;;
    *) echo "无效选项"; pause ;;
  esac
done
