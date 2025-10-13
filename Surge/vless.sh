#!/bin/bash
# ==============================================================================
# Xray VLESS-Reality 一键安装管理脚本（改版）
# 版本: V-Final-3.0
# 变更点：
# - 新增：监听地址可选 0.0.0.0 / 127.0.0.1（安装、修改配置、命令行 --listen）
# - 新增：自带 Xray 就地更新（GitHub Releases，备份/回滚），保留官方 geodata 更新
# - 新增：本脚本自更新（从你提供的仓库 raw 地址拉取）
# - 修复：x25519 公钥字段解析
# ==============================================================================

set -euo pipefail

# --- 可自定义 ---
readonly SCRIPT_VERSION="V-Final-3.0"
readonly SCRIPT_URL="https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/vless.sh"

readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_SERVICE="xray"

readonly XRAY_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly GITHUB_API_RELEASES="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

# --- 颜色 ---
red='\e[91m'; green='\e[92m'; yellow='\e[93m'; cyan='\e[96m'; none='\e[0m'

# --- 全局 ---
is_quiet=false
xray_status_info=""

# -------------------- 小工具 --------------------
msg() { [[ "$is_quiet" = false ]] && echo -e "$*"; }
ok()  { msg "\n${green}[✔]${none} $*"; }
warn(){ msg "\n${yellow}[!]${none} $*"; }
err() { echo -e "\n${red}[✖]${none} $*" >&2; }

spin() {
  local pid=$1; local s='-\|/'; local i=0
  [[ "$is_quiet" = true ]] && wait "$pid" && return
  while kill -0 "$pid" 2>/dev/null; do
    i=$(((i+1)%4)); printf " [%s] \r" "${s:$i:1}"; sleep 0.1
  done; printf "     \r"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "缺少依赖：$1"; return 1; }
}

# -------------------- 系统与依赖 --------------------
pre_check() {
  [[ $(id -u) -ne 0 ]] && err "必须使用 root 运行" && exit 1

  # 常用依赖
  local pkgs=(jq curl unzip)
  local to_install=()
  for p in "${pkgs[@]}"; do command -v "$p" >/dev/null || to_install+=("$p"); done
  if ((${#to_install[@]})); then
    warn "安装依赖：${to_install[*]}"
    (DEBIAN_FRONTEND=noninteractive apt-get update &&
     DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}") >/dev/null 2>&1 &
    spin $!
  fi
}

# -------------------- 通用校验 --------------------
is_valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((1<= $1 && $1<=65535)); }
is_port_in_use(){
  if command -v ss >/dev/null; then ss -tuln | grep -q ":$1 "
  elif command -v netstat >/dev/null; then netstat -tuln | grep -q ":$1 "
  else timeout 1 bash -c "</dev/tcp/127.0.0.1/$1" 2>/dev/null; fi
}
is_uuid(){ [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
is_domain(){ [[ "$1" =~ ^[A-Za-z0-9-]{1,63}(\.[A-Za-z0-9-]{1,63})+$ ]] && [[ "$1" != *--* ]]; }

get_public_ip() {
  local ip
  for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
    for url in https://api.ipify.org https://checkip.amazonaws.com https://ip.sb; do
      ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
    done
  done
  echo "0.0.0.0"
}

# -------------------- 监听地址选择 --------------------
prompt_listen_addr() {
  echo -e "\n选择监听地址："
  echo "  1) 0.0.0.0   （默认，对外可连）"
  echo "  2) 127.0.0.1 （仅本机；配合 Nginx stream 分流更隐蔽）"
  read -p "输入 1/2 [默认 1]: " sel
  case "${sel:-1}" in
    2) echo "127.0.0.1" ;;
    *) echo "0.0.0.0" ;;
  esac
}

# -------------------- Xray 安装/更新 --------------------
exec_official() {
  local args="$1"
  local sc; sc=$(curl -fsSL "$XRAY_INSTALLER_URL") || { err "下载官方安装脚本失败"; return 1; }
  bash -c "$sc" @ $args
}

arch_tag() {
  local u=$(uname -m)
  case "$u" in
    x86_64|amd64) echo "linux-64" ;;
    i386|i686)    echo "linux-32" ;;
    aarch64|arm64)echo "linux-arm64-v8a" ;;
    armv7l)       echo "linux-arm32-v7a" ;;
    armv6l)       echo "linux-arm32-v5" ;;
    mips64le)     echo "linux-mips64le" ;;
    mips64)       echo "linux-mips64" ;;
    mipsle)       echo "linux-mipsle" ;;
    *) err "未知架构：$u"; return 1 ;;
  esac
}

download_latest_xray() {
  # 返回：临时解压目录路径
  local tag asset url tmp zip
  local arch=$(arch_tag) || return 1

  tag=$(curl -fsSL "$GITHUB_API_RELEASES" | jq -r .tag_name) || { err "获取最新版本失败"; return 1; }
  asset=$(curl -fsSL "$GITHUB_API_RELEASES" | jq -r ".assets[].name" | grep -E "^Xray-${arch}(-v)?[0-9\.]*\.zip$" | head -n1)
  [[ -z "$asset" ]] && asset="Xray-${arch}.zip"

  url=$(curl -fsSL "$GITHUB_API_RELEASES" | jq -r ".assets[] | select(.name==\"$asset\").browser_download_url")
  [[ -z "$url" ]] && { err "找不到匹配的发布包：$asset"; return 1; }

  tmp=$(mktemp -d)
  zip="$tmp/$asset"
  warn "下载 $asset ..."
  curl -fL --retry 3 -o "$zip" "$url"
  warn "解压 ..."
  unzip -q "$zip" -d "$tmp"
  echo "$tmp"
}

install_xray_files() {
  local dir="$1"
  [[ -x "$dir/xray" ]] || { err "解压包中没有 xray 可执行文件"; return 1; }

  # 备份旧二进制
  if [[ -x "$XRAY_BIN" ]]; then
    cp -a "$XRAY_BIN" "${XRAY_BIN}.bak.$(date +%s)" || true
  fi

  install -m 755 "$dir/xray" "$XRAY_BIN"
  # 可选：同步 geo 文件（若你愿意也可以）
  [[ -f "$dir/geoip.dat" ]]   && install -m 644 "$dir/geoip.dat"   /usr/local/share/xray/geoip.dat
  [[ -f "$dir/geosite.dat" ]] && install -m 644 "$dir/geosite.dat" /usr/local/share/xray/geosite.dat
}

update_xray_core() {
  need_cmd curl; need_cmd jq; need_cmd unzip
  local d; d=$(download_latest_xray) || return 1
  install_xray_files "$d" || return 1

  systemctl restart "$XRAY_SERVICE" || true
  sleep 1
  if ! systemctl is-active --quiet "$XRAY_SERVICE"; then
    err "Xray 重启失败，尝试回滚（请检查日志：journalctl -u $XRAY_SERVICE）"
    # 回滚（若存在备份）
    if [[ -f "${XRAY_BIN}.bak"* ]]; then
      cp -af "$(ls -1t ${XRAY_BIN}.bak.* | head -n1)" "$XRAY_BIN"
      systemctl restart "$XRAY_SERVICE" || true
    fi
    return 1
  fi
  ok "Xray 核心更新完成：$("$XRAY_BIN" version | head -n1)"
}

update_geodata() {
  warn "更新 GeoIP/GeoSite（官方脚本）..."
  exec_official "install-geodata" || warn "geodata 更新失败（可忽略，稍后再试）"
}

# -------------------- 配置生成 --------------------
write_config() {
  local port="$1" uuid="$2" sni="$3" priv="$4" pub="$5" listen_addr="$6"
  local shortid="20220701"
  jq -n \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg sni "$sni" \
    --arg private_key "$priv" \
    --arg public_key "$pub" \
    --arg shortid "$shortid" \
    --arg listen "$listen_addr" \
  '{
    "log": {"loglevel": "warning"},
    "inbounds": [{
      "listen": $listen,
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": ($sni + ":443"),
          "xver": 0,
          "serverNames": [$sni],
          "privateKey": $private_key,
          "publicKey": $public_key,
          "shortIds": [$shortid]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    }],
    "outbounds": [{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}]
  }' > "$XRAY_CONFIG"
}

restart_xray() {
  systemctl restart "$XRAY_SERVICE" || { err "重启 $XRAY_SERVICE 失败"; return 1; }
  sleep 1
  systemctl is-active --quiet "$XRAY_SERVICE" || { err "$XRAY_SERVICE 未在运行"; return 1; }
  ok "Xray 已重启"
}

# -------------------- 菜单动作 --------------------
check_xray_status() {
  local ver="未安装"
  [[ -x "$XRAY_BIN" ]] && ver="$("$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}')"
  local active="未运行"; systemctl is-active --quiet "$XRAY_SERVICE" && active="运行中"
  xray_status_info="Xray：$ver（$active） | 配置：$XRAY_CONFIG"
}

install_xray() {
  # 端口
  local port; read -p "$(echo -e "端口 [1-65535]（默认 ${cyan}443${none}）：")" port
  port=${port:-443}
  is_valid_port "$port" || { err "端口无效"; return; }
  if is_port_in_use "$port"; then err "端口 $port 已占用"; return; fi

  # UUID
  local uuid; read -p "UUID（留空自动生成）： " uuid
  [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
  is_uuid "$uuid" || { err "UUID 格式不对"; return; }

  # SNI
  local sni; read -p "$(echo -e "SNI 伪装域名（默认 ${cyan}learn.microsoft.com${none}）：")" sni
  sni=${sni:-learn.microsoft.com}
  is_domain "$sni" || { err "域名格式不对"; return; }

  # 监听地址
  local listen_addr; listen_addr=$(prompt_listen_addr)

  warn "安装/更新 Xray 核心 ..."
  exec_official "install" || { err "官方安装失败"; return; }

  warn "生成 Reality 密钥对 ..."
  local kp; kp=$("$XRAY_BIN" x25519)
  local priv=$(echo "$kp" | awk '/Private key/ {print $3}')
  local pub=$( echo "$kp" | awk '/Public key/  {print $3}')
  [[ -n "$priv" && -n "$pub" ]] || { err "生成密钥失败"; return; }

  warn "写入配置 ..."
  mkdir -p "$(dirname "$XRAY_CONFIG")"
  write_config "$port" "$uuid" "$sni" "$priv" "$pub" "$listen_addr"

  systemctl enable --now "$XRAY_SERVICE"
  restart_xray || return

  ok "安装完成"
  view_subscription_info
}

modify_config() {
  [[ -f "$XRAY_CONFIG" ]] || { err "未安装"; return; }
  local cur_port cur_uuid cur_sni cur_listen priv pub
  cur_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
  cur_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
  cur_sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")
  cur_listen=$(jq -r '.inbounds[0].listen' "$XRAY_CONFIG")
  priv=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")
  pub=$( jq -r '.inbounds[0].streamSettings.realitySettings.publicKey'  "$XRAY_CONFIG")

  echo -e "直接回车保留原值。"
  local port uuid sni listen_addr

  read -p "端口（当前 $cur_port）： " port
  port=${port:-$cur_port}
  is_valid_port "$port" || { err "端口无效"; return; }
  if [[ "$port" != "$cur_port" ]] && is_port_in_use "$port"; then err "端口占用"; return; fi

  read -p "UUID（当前 $cur_uuid）： " uuid
  uuid=${uuid:-$cur_uuid}
  is_uuid "$uuid" || { err "UUID 无效"; return; }

  read -p "SNI（当前 $cur_sni）： " sni
  sni=${sni:-$cur_sni}
  is_domain "$sni" || { err "域名无效"; return; }

  echo -e "\n监听地址（当前 ${cur_listen:-0.0.0.0}）："
  listen_addr=$(prompt_listen_addr)
  [[ -z "$listen_addr" ]] && listen_addr="${cur_listen:-0.0.0.0}"

  write_config "$port" "$uuid" "$sni" "$priv" "$pub" "$listen_addr"
  restart_xray || return
  ok "配置已更新"
  view_subscription_info
}

view_subscription_info() {
  [[ -f "$XRAY_CONFIG" ]] || { err "配置不存在"; return; }
  local ip; ip=$(get_public_ip)
  local uuid port sni pub sid
  uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
  port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
  sni=$( jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")
  pub=$( jq -r '.inbounds[0].streamSettings.realitySettings.publicKey'  "$XRAY_CONFIG")
  sid=$( jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")

  local name="$(hostname) X-reality"
  local enc_name=$(printf '%s' "$name" | sed 's/ /%20/g')
  local vless="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}#${enc_name}"

  echo "----------------------------------------------------------------"
  echo -e "${green}订阅：${none} $vless"
  echo "----------------------------------------------------------------"
}

uninstall_xray() {
  read -p "确认卸载 Xray？[y/N]: " c
  [[ "$c" =~ ^[yY]$ ]] || { warn "已取消"; return; }
  systemctl stop "$XRAY_SERVICE" || true
  exec_official "remove --purge" || true
  rm -f "$XRAY_CONFIG"
  ok "已卸载。"
}

view_log() {
  journalctl -u "$XRAY_SERVICE" -f --no-pager
}

self_update() {
  [[ -z "$SCRIPT_URL" ]] && { err "未设置 SCRIPT_URL"; return 1; }
  local tmp; tmp=$(mktemp)
  warn "从远程拉取脚本：$SCRIPT_URL"
  if ! curl -fsSL "$SCRIPT_URL" -o "$tmp"; then err "下载失败"; rm -f "$tmp"; return 1; fi
  chmod +x "$tmp"
  mv "$tmp" "$0"
  ok "脚本已更新到最新版本（$SCRIPT_VERSION → 远程）"
}

# -------------------- 菜单 --------------------
menu() {
  while true; do
    clear
    echo -e "${cyan}Xray VLESS-Reality 管理脚本 ${SCRIPT_VERSION}${none}"
    echo "---------------------------------------------"
    check_xray_status; echo -e "$xray_status_info"
    echo "---------------------------------------------"
    echo -e "  ${green}1.${none} 安装/重装 Xray"
    echo -e "  ${cyan}2.${none} 更新 Xray 核心（GitHub Releases）"
    echo -e "  ${cyan}3.${none} 更新 Geo 数据（官方脚本）"
    echo -e "  ${yellow}4.${none} 重启 Xray"
    echo -e "  ${red}5.${none} 卸载 Xray"
    echo -e "  ${magenta}6.${none} 查看日志"
    echo -e "  ${green}7.${none} 修改节点配置（含监听地址）"
    echo -e "  ${green}8.${none} 更新本脚本"
    echo -e "  ${yellow}9.${none} 查看订阅链接"
    echo -e "  ${cyan}0.${none} 退出"
    echo "---------------------------------------------"
    read -p "选择 [0-9]: " a
    case "$a" in
      1) install_xray ;;
      2) update_xray_core ;;
      3) update_geodata ;;
      4) restart_xray ;;
      5) uninstall_xray ;;
      6) view_log ;;
      7) modify_config ;;
      8) self_update ;;
      9) view_subscription_info ;;
      0) exit 0 ;;
      *) err "无效选项" ;;
    esac
    read -p "回车返回菜单..." _ || true
  done
}

# -------------------- 非交互入口 --------------------
main() {
  pre_check
  if [[ $# -gt 0 && "$1" == "install" ]]; then
    shift
    local port=443 uuid="" sni="learn.microsoft.com" listen="0.0.0.0"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --port)   port="$2"; shift 2 ;;
        --uuid)   uuid="$2"; shift 2 ;;
        --sni)    sni="$2";  shift 2 ;;
        --listen) listen="$2"; shift 2 ;;  # 新增：--listen 0.0.0.0|127.0.0.1
        --quiet|-q) is_quiet=true; shift ;;
        *) err "未知参数：$1"; exit 1 ;;
      esac
    done
    is_valid_port "$port" || { err "端口无效"; exit 1; }
    [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
    is_uuid "$uuid" || { err "UUID 无效"; exit 1; }
    is_domain "$sni" || { err "SNI 域名无效"; exit 1; }
    [[ "$listen" == "0.0.0.0" || "$listen" == "127.0.0.1" ]] || { err "--listen 仅支持 0.0.0.0 / 127.0.0.1"; exit 1; }

    exec_official "install"
    local kp; kp=$("$XRAY_BIN" x25519)
    local priv=$(echo "$kp" | awk '/Private key/ {print $3}')
    local pub=$( echo "$kp" | awk '/Public key/  {print $3}')
    write_config "$port" "$uuid" "$sni" "$priv" "$pub" "$listen"
    systemctl enable --now "$XRAY_SERVICE"
    restart_xray
    [[ "$is_quiet" = true ]] || view_subscription_info
  else
    menu
  fi
}

main "$@"
