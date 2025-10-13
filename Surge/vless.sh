#!/usr/bin/env bash
set -Euo pipefail

#================= 脚本元信息（自升级/自安装） =================
SCRIPT_VERSION="3.1.4"
SCRIPT_INSTALL="/usr/local/sbin/vless.sh"
SCRIPT_LAUNCHER="/usr/local/bin/vless"
SCRIPT_URL="https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/vless.sh"

#================= Xray 基本配置 =================
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="xray"

XRAY_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
GITHUB_API_RELEASES="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

#================= 颜色 =================
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"

#---------------- helpers ----------------
need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo -e "${RED}请用 root 运行${RESET}"; exit 1; }; }
require_pkg(){ local miss=(); for p in "$@"; do command -v "$p" >/dev/null || miss+=("$p"); done; [ ${#miss[@]} -eq 0 ] || (apt update && apt install -y "${miss[@]}"); }
pause(){ echo; read -rp "按回车返回菜单..." _ || true; }

normalize_ver(){ echo "${1:-}" | sed 's/^v//'; }
version_gt(){ [ "$(printf '%s\n%s\n' "$(normalize_ver "$1")" "$(normalize_ver "$2")" | sort -V | tail -n1)" != "$(normalize_ver "$2")" ]; }

is_valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((1<= $1 && $1<=65535)); }
is_uuid(){ [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
is_domain(){ [[ "$1" =~ ^[A-Za-z0-9-]{1,63}(\.[A-Za-z0-9-]{1,63})+$ ]] && [[ "$1" != *--* ]]; }

is_port_in_use(){
  if command -v ss >/dev/null; then ss -tuln | grep -q ":$1 "
  elif command -v netstat >/dev/null; then netstat -tuln | grep -q ":$1 "
  else timeout 1 bash -c "</dev/tcp/127.0.0.1/$1" 2>/dev/null; fi
}

get_public_ip(){
  local ip; ip=$(curl -fsSL --max-time 5 https://api.ipify.org || true)
  [ -n "$ip" ] || ip=$(curl -fsSL --max-time 5 https://checkip.amazonaws.com || true)
  [ -n "$ip" ] || ip=$(curl -fsSL --max-time 5 https://ip.sb || true)
  echo "${ip:-0.0.0.0}"
}

#---------------- 自安装/启动器/自更新 ----------------
ensure_installed_as_command() {
  mkdir -p "$(dirname "$SCRIPT_INSTALL")"
  local self; self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  if [[ "$self" == /proc/*/fd/* ]]; then
    curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_INSTALL"
    chmod +x "$SCRIPT_INSTALL"
  else
    if [ "$self" != "$SCRIPT_INSTALL" ]; then
      install -m 0755 "$self" "$SCRIPT_INSTALL"
    fi
  fi
  cat > "$SCRIPT_LAUNCHER" <<'LAUNCH'
#!/usr/bin/env bash
exec bash /usr/local/sbin/vless.sh "$@"
LAUNCH
  chmod +x "$SCRIPT_LAUNCHER"
}

remote_script_version(){
  curl -fsSL "$SCRIPT_URL" | grep -m1 '^SCRIPT_VERSION=' | sed 's/^SCRIPT_VERSION=//; s/"//g'
}

self_update(){
  require_pkg curl
  local remote; remote="$(remote_script_version || true)"
  [ -z "${remote:-}" ] && { echo "获取远端脚本版本失败。"; return 1; }
  echo "本地脚本：$SCRIPT_VERSION"
  echo "远端脚本：$remote"
  if version_gt "$remote" "$SCRIPT_VERSION"; then
    echo "发现新版本，更新中..."
    curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_INSTALL"
    chmod +x "$SCRIPT_INSTALL"
    exec bash "$SCRIPT_INSTALL"
  else
    echo "脚本已是最新。"
  fi
}

#---------------- Xray 安装/更新 ----------------
exec_official(){
  local sc; sc=$(curl -fsSL "$XRAY_INSTALLER_URL") || { echo -e "${RED}下载官方脚本失败${RESET}"; return 1; }
  bash -c "$sc" @ $1
}

arch_tag(){
  case "$(uname -m)" in
    x86_64|amd64) echo "linux-64" ;;
    aarch64|arm64) echo "linux-arm64-v8a" ;;
    armv7l) echo "linux-arm32-v7a" ;;
    i386|i686) echo "linux-32" ;;
    *) echo "unknown" ;;
  esac
}

download_latest_xray(){
  local arch; arch=$(arch_tag); [ "$arch" = "unknown" ] && { echo "unknown"; return 1; }
  local meta; meta=$(curl -fsSL "$GITHUB_API_RELEASES") || return 1
  local asset; asset=$(echo "$meta" | jq -r ".assets[].name" | grep -E "^Xray-${arch}.*\.zip$" | head -n1)
  local url; url=$(echo "$meta" | jq -r ".assets[] | select(.name==\"$asset\").browser_download_url")
  echo "$url"
}

update_xray_core(){
  require_pkg curl jq unzip
  local cur ver url tmp
  cur=$("$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}' || echo "")
  ver=$(curl -fsSL "$GITHUB_API_RELEASES" | jq -r .tag_name | sed 's/^v//')
  [ -z "$ver" ] && { echo "无法获取最新版本"; return 1; }
  if [ -n "$cur" ] && ! version_gt "$ver" "$cur"; then
    echo "已是最新（$cur）"; return 0
  fi
  url=$(download_latest_xray) || { echo "下载地址获取失败"; return 1; }
  tmp=$(mktemp -d)
  curl -fL --retry 3 -o "$tmp/xray.zip" "$url" || { echo "下载失败"; rm -rf "$tmp"; return 1; }
  unzip -q "$tmp/xray.zip" -d "$tmp"
  install -m 0755 "$tmp/xray" "$XRAY_BIN"
  mkdir -p /usr/local/share/xray
  [ -f "$tmp/geoip.dat" ]   && install -m 0644 "$tmp/geoip.dat"   /usr/local/share/xray/geoip.dat
  [ -f "$tmp/geosite.dat" ] && install -m 0644 "$tmp/geosite.dat" /usr/local/share/xray/geosite.dat
  rm -rf "$tmp"
  systemctl restart "$XRAY_SERVICE" || true
  sleep 1
  systemctl is-active --quiet "$XRAY_SERVICE" && echo "Xray 已更新到 $("$XRAY_BIN" version | head -n1)" || echo "Xray 重启失败，检查日志。"
}

update_geodata(){
  echo "通过官方脚本更新 geodata ..."
  exec_official "install-geodata" || echo "geodata 更新失败，可稍后重试"
}

#---------------- 配置生成 ----------------
prompt_listen_addr(){
  # 把选项直接放到同一行提示里，避免前面说明被清屏/吞掉
  local prompt=$'Listen address  1=0.0.0.0 (public) / 2=127.0.0.1 (loopback, via Nginx)\nChoose [1/2, default 1]: '
  read -rp "$prompt" n
  n="${n:-1}"
  [[ "$n" = "2" ]] && echo "127.0.0.1" || echo "0.0.0.0"
}

write_config(){
  local port="$1" uuid="$2" sni="$3" priv="$4" pub="$5" listen="$6" shortid="20220701"
  mkdir -p "$(dirname "$XRAY_CONFIG")"
  jq -n \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg sni "$sni" \
    --arg private_key "$priv" \
    --arg public_key "$pub" \
    --arg shortid "$shortid" \
    --arg listen "$listen" \
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
  chmod 644 "$XRAY_CONFIG"
}

restart_xray(){
  systemctl enable "$XRAY_SERVICE" >/dev/null 2>&1 || true
  if ! systemctl restart "$XRAY_SERVICE"; then
    echo -e "${YELLOW}⚠️ 重启失败，查看日志：journalctl -u $XRAY_SERVICE -e --no-pager${RESET}"
    return 1
  fi
  for i in {1..8}; do
    if systemctl is-active --quiet "$XRAY_SERVICE"; then
      echo -e "${GREEN}✅ Xray 已运行${RESET}"
      return 0
    fi
    sleep 1
  done
  echo -e "${YELLOW}⚠️ Xray 未在运行，检查日志：journalctl -u $XRAY_SERVICE -e --no-pager${RESET}"
  return 1
}

#---------------- 安装/修改/信息 ----------------
install_xray(){
  require_pkg curl jq
  local port uuid sni listen
  read -rp "$(echo -e "端口 [1-65535]（默认 ${CYAN}443${RESET}）：")" port; port=${port:-443}
  is_valid_port "$port" || { echo -e "${RED}端口无效${RESET}"; return; }
  is_port_in_use "$port" && { echo -e "${RED}端口被占用${RESET}"; return; }

  read -rp "UUID（留空自动生成）： " uuid; uuid=${uuid:-$(cat /proc/sys/kernel/random/uuid)}
  is_uuid "$uuid" || { echo -e "${RED}UUID 无效${RESET}"; return; }

  read -rp "$(echo -e "SNI 伪装域名（默认 ${CYAN}learn.microsoft.com${RESET}）：")" sni; sni=${sni:-learn.microsoft.com}
  is_domain "$sni" || { echo -e "${RED}域名无效${RESET}"; return; }

  listen=$(prompt_listen_addr)

  echo "安装/更新 Xray 核心 ..."
  exec_official "install" || { echo -e "${RED}官方安装脚本失败${RESET}"; return; }
  systemctl stop "$XRAY_SERVICE" >/dev/null 2>&1 || true

  echo "生成 Reality 密钥对 ..."
  local out priv pub
  out="$("$XRAY_BIN" x25519 2>&1 || true)"
  priv="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /^private[[:space:]]*key$/ {print $2; exit}' | sed 's/[[:space:]]*$//')"
  pub="$( printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /^(public[[:space:]]*key|publickey|password)$/ {print $2; exit}' | sed 's/[[:space:]]*$//')"
  if [[ -z "$priv" || -z "$pub" ]]; then
    echo -e "${RED}生成密钥失败：无法从 xray 输出中解析${RESET}"
    echo "—— xray x25519 原始输出 ——"
    echo "$out"
    return 1
  fi

  write_config "$port" "$uuid" "$sni" "$priv" "$pub" "$listen"
  restart_xray || return
  view_info
}

modify_config(){
  [ -f "$XRAY_CONFIG" ] || { echo "未安装"; return; }
  local cur_port cur_uuid cur_sni cur_listen priv pub
  cur_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
  cur_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
  cur_sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")
  cur_listen=$(jq -r '.inbounds[0].listen // "0.0.0.0"' "$XRAY_CONFIG")
  priv=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")
  pub=$( jq -r '.inbounds[0].streamSettings.realitySettings.publicKey'  "$XRAY_CONFIG")

  local port uuid sni listen
  read -rp "端口（当前 $cur_port）： " port; port=${port:-$cur_port}
  is_valid_port "$port" || { echo "端口无效"; return; }
  if [[ "$port" != "$cur_port" ]] && is_port_in_use "$port"; then echo "端口占用"; return; fi

  read -rp "UUID（当前 $cur_uuid）： " uuid; uuid=${uuid:-$cur_uuid}; is_uuid "$uuid" || { echo "UUID 无效"; return; }
  read -rp "SNI（当前 $cur_sni）： " sni;   sni=${sni:-$cur_sni};   is_domain "$sni" || { echo "域名无效"; return; }

  listen=$(prompt_listen_addr); listen=${listen:-$cur_listen}

  write_config "$port" "$uuid" "$sni" "$priv" "$pub" "$listen"
  restart_xray || return
  view_info
}

view_info(){
  [ -f "$XRAY_CONFIG" ] || { echo "未安装"; return; }
  local ip uuid port sni pub sid
  ip=$(get_public_ip)
  uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
  port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
  sni=$( jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")
  pub=$( jq -r '.inbounds[0].streamSettings.realitySettings.publicKey'  "$XRAY_CONFIG")
  sid=$( jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")
  local name="$(hostname) X-reality"; local enc=$(printf '%s' "$name" | sed 's/ /%20/g')
  local link="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}#${enc}"
  echo "----------------------------------------------------------------"
  echo -e "${GREEN}订阅：${RESET} $link"
  echo "----------------------------------------------------------------"
}

uninstall_xray(){
  read -rp "确认卸载 Xray？[y/N]: " c; [[ "$c" =~ ^[yY]$ ]] || { echo "已取消"; return; }
  systemctl stop "$XRAY_SERVICE" 2>/dev/null || true
  exec_official "remove --purge" || true
  rm -f "$XRAY_CONFIG"
  echo "已卸载 Xray。"
}

view_log(){ journalctl -u "$XRAY_SERVICE" -f --no-pager; }

#---------------- 菜单 ----------------
show_header(){
  local ver active
  ver=$("$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $2}' || echo "-")
  systemctl is-active --quiet "$XRAY_SERVICE" && active="运行中" || active="未运行"
  echo "================================================"
  echo "  Xray VLESS-Reality 管理界面"
  echo "  状态：$active    版本：$ver"
  echo "  配置：$XRAY_CONFIG"
  echo "  脚本：$SCRIPT_VERSION"
  echo "================================================"
}

menu_loop(){
  while true; do
    clear; show_header
    echo "1) 安装/重装 Xray（含监听地址选择）"
    echo "2) 更新 Xray 核心（GitHub Releases）"
    echo "3) 更新 Geo 数据（官方脚本）"
    echo "4) 重启 Xray"
    echo "5) 卸载 Xray"
    echo "6) 查看日志"
    echo "7) 修改配置（端口/UUID/SNI/监听地址）"
    echo "8) 查看订阅链接"
    echo "9) 更新本脚本"
    echo "0) 退出"
    echo "-----------------------------------------------"
    read -rp "请选择 [0-9]: " n
    case "${n:-}" in
      1) install_xray; pause ;;
      2) update_xray_core; pause ;;
      3) update_geodata; pause ;;
      4) restart_xray; pause ;;
      5) uninstall_xray; pause ;;
      6) view_log ;;
      7) modify_config; pause ;;
      8) view_info; pause ;;
      9) self_update; ;;
      0) exit 0 ;;
      *) echo "无效选项"; pause ;;
    esac
  done
}

#---------------- 非交互入口 ----------------
main(){
  need_root
  require_pkg curl jq
  ensure_installed_as_command

  if [[ $# -gt 0 && "$1" == "install" ]]; then
    shift
    local port=443 uuid="" sni="learn.microsoft.com" listen="0.0.0.0"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --port)   port="$2"; shift 2 ;;
        --uuid)   uuid="$2"; shift 2 ;;
        --sni)    sni="$2";  shift 2 ;;
        --listen) listen="$2"; shift 2 ;; # 0.0.0.0 | 127.0.0.1
        *) echo "未知参数：$1"; exit 1 ;;
      esac
    done
    is_valid_port "$port" || { echo "端口无效"; exit 1; }
    [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
    is_uuid "$uuid" || { echo "UUID 无效"; exit 1; }
    is_domain "$sni" || { echo "SNI 域名无效"; exit 1; }
    [[ "$listen" == "0.0.0.0" || "$listen" == "127.0.0.1" ]] || { echo "--listen 仅支持 0.0.0.0/127.0.0.1"; exit 1; }

    exec_official "install" || { echo "官方安装失败"; exit 1; }
    systemctl stop "$XRAY_SERVICE" >/dev/null 2>&1 || true

    local out priv pub
    out="$("$XRAY_BIN" x25519 2>&1 || true)"
    priv="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /^private[[:space:]]*key$/ {print $2; exit}' | sed 's/[[:space:]]*$//')"
    pub="$( printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /^(public[[:space:]]*key|publickey|password)$/ {print $2; exit}' | sed 's/[[:space:]]*$//')"
    [ -n "$priv" ] && [ -n "$pub" ] || { echo "x25519 输出无法解析："; echo "$out"; exit 1; }

    write_config "$port" "$uuid" "$sni" "$priv" "$pub" "$listen"
    restart_xray || exit 1
    view_info
  else
    menu_loop
  fi
}

main "$@"
