#!/usr/bin/env bash
# port - one-key port switcher for TUIC / Shoes / ShadowQUIC
# Run as root. No sudo/switch alias. No port-occupancy or running-state checks.

set -euo pipefail

# ---------- Config ----------
avail_ports=(443 4443 8443)

declare -A LABEL CONF UNIT
LABEL[tuic]="TUIC"
CONF[tuic]="/etc/tuic/config.json"
UNIT[tuic]="/etc/systemd/system/tuic-server.service"

LABEL[shoes]="Shoes"
CONF[shoes]="/etc/shoes/config.yml"
UNIT[shoes]="/etc/systemd/system/shoes.service"

LABEL[shadowquic]="ShadowQUIC"
CONF[shadowquic]="/etc/shadowquic/server.yaml"
UNIT[shadowquic]="/etc/systemd/system/shadowquic.service"

order=(tuic shoes shadowquic)

# ---------- Helpers ----------
die() { echo "Error: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "必须以 root 运行。"; }
unit_exists() { [[ -f "$1" ]]; }
installed_service() {
  local app="$1"
  unit_exists "${UNIT[$app]}" && [[ -f "${CONF[$app]}" ]]
}

current_port() {
  local app="$1" file="${CONF[$app]}"
  [[ -f "$file" ]] || { echo ""; return; }
  case "$app" in
    tuic)
      sed -nE 's/.*"server"[[:space:]]*:[[:space:]]*"\[::\]:([0-9]+)".*/\1/p' "$file" | head -n1
      ;;
    shoes)
      sed -nE 's/^[[:space:]]*-?[[:space:]]*address:[[:space:]]*"\[::\]:([0-9]+)".*/\1/p' "$file" | head -n1
      ;;
    shadowquic)
      sed -nE 's/^[[:space:]]*bind-addr:[[:space:]]*"\[::\]:([0-9]+)".*/\1/p' "$file" | head -n1
      ;;
  esac
}

update_config() {
  local app="$1" newp="$2" file="${CONF[$app]}"
  [[ -f "$file" ]] || die "未找到配置文件：$file"
  case "$app" in
    tuic)
      sed -E -i 's#("server"[[:space:]]*:[[:space:]]*")\[::\]:[0-9]+(")#\1[::]:'"$newp"'\2#' "$file"
      ;;
    shoes)
      sed -E -i 's#(^[[:space:]]*-?[[:space:]]*address:[[:space:]]*")\[::\]:[0-9]+(")#\1[::]:'"$newp"'\2#' "$file"
      ;;
    shadowquic)
      sed -E -i 's#(^[[:space:]]*bind-addr:[[:space:]]*")\[::\]:[0-9]+(")#\1[::]:'"$newp"'\2#' "$file"
      ;;
  esac
}

choose_port() {
  while :; do
    echo -n "  请选择端口： "
    local i=1
    for p in "${avail_ports[@]}"; do printf "%d)%d  " "$i" "$p"; ((i++)); done
    echo
    read -rp "  输入序号(1-${#avail_ports[@]}): " ans
    [[ "$ans" =~ ^[1-9][0-9]*$ ]] || { echo "  无效输入"; continue; }
    (( ans>=1 && ans<=${#avail_ports[@]} )) || { echo "  超出范围"; continue; }
    local idx=$((ans-1))
    CHOSEN_PORT="${avail_ports[$idx]}"
    local newlist=(); for j in "${!avail_ports[@]}"; do [[ $j -ne $idx ]] && newlist+=("${avail_ports[$j]}"); done
    avail_ports=("${newlist[@]}")
    return 0
  done
}

restart_service() {
  local unit_path="$1"
  local unit="$(basename "$unit_path")"
  systemctl restart "$unit"
}

print_usage() {
  cat <<USAGE
port - TUIC / Shoes / ShadowQUIC 端口切换工具
用法：
  ./port             进入交互式向导
  ./port --install   安装为 /usr/local/bin/port
USAGE
}

do_install() { install -m 0755 "$0" /usr/local/bin/port && echo "已安装为 /usr/local/bin/port"; }

# ---------- Main ----------
need_root
if [[ "${1:-}" == "--install" ]]; then do_install; exit 0; fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then print_usage; exit 0; fi

installed=()
echo "=== 检测安装（仅检查 unit+配置是否存在） ==="
for app in "${order[@]}"; do
  if installed_service "$app"; then
    installed+=("$app")
    cur="$(current_port "$app")"; [[ -z "$cur" ]] && cur="未知"
    echo " - ${LABEL[$app]}: 已安装（${cur}）"
  else
    echo " - ${LABEL[$app]}: 未安装（跳过）"
  fi
done
[[ ${#installed[@]} -gt 0 ]] || { echo "未发现已安装的目标服务，退出。"; exit 0; }

declare -A chosen
echo
for app in "${installed[@]}"; do
  echo "为 ${LABEL[$app]} 选择端口（动态重排菜单）："
  choose_port
  chosen["$app"]="$CHOSEN_PORT"
done

echo
echo "=== 将要应用的修改（仅监听端口字段） ==="
for app in "${installed[@]}"; do
  oldp="$(current_port "$app")"; [[ -z "$oldp" ]] && oldp="未知"
  printf " - %-12s: %s -> %s\n" "${LABEL[$app]}" "$oldp" "${chosen[$app]}"
done
read -rp $'按回车执行修改并重启对应服务（Ctrl+C 取消）…'

for app in "${installed[@]}"; do
  update_config "$app" "${chosen[$app]}"
done

systemctl daemon-reload
for app in "${installed[@]}"; do
  restart_service "${UNIT[$app]}"
done

echo "完成。"
