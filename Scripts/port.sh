#!/usr/bin/env bash
# port - one-key port switcher for TUIC / Shoes / ShadowQUIC
# Requirements:
#   - Run as root (needs to edit /etc/* and restart systemd units)
#   - Debian/Ubuntu with systemd
# Behavior:
#   - Detect "installed" services by (unit exists) AND (config file exists)
#   - For each installed service, ask a port from {443, 4443, 8443}
#     with dynamic, re-numbered menu (e.g., if 443 taken, next shows 1)4443 2)8443)
#   - Only modify the listening port field (no other fields touched, no port-occupancy check)
#   - Apply changes, systemctl daemon-reload once, then restart corresponding services

set -euo pipefail

# ---------- Config ----------
# Port pool (order shown to the first service; later menus re-number dynamically)
avail_ports=(443 4443 8443)

# Service metadata
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

# Order to prompt
order=(tuic shoes shadowquic)

# ---------- Helpers ----------
die() { echo "Error: $*" >&2; exit 1; }

need_root() {
  [[ $EUID -eq 0 ]] || die "必须以 root 运行。"
}

unit_exists() {
  # Accept unit being placed in /etc/systemd/system only (explicit paths above)
  [[ -f "$1" ]]
}

installed_service() {
  local app="$1"
  unit_exists "${UNIT[$app]}" && [[ -f "${CONF[$app]}" ]]
}

current_port() {
  local app="$1" file="${CONF[$app]}"
  [[ -f "$file" ]] || { echo ""; return; }
  case "$app" in
    tuic)
      # "server": "[::]:443"
      sed -nE 's/.*"server"[[:space:]]*:[[:space:]]*"\[::\]:([0-9]+)".*/\1/p' "$file" | head -n1
      ;;
    shoes)
      # - address: "[::]:8443" (also tolerate optional leading dash)
      sed -nE 's/^[[:space:]]*-?[[:space:]]*address:[[:space:]]*"\[::\]:([0-9]+)".*/\1/p' "$file" | head -n1
      ;;
    shadowquic)
      # bind-addr: "[::]:443"
      sed -nE 's/^[[:space:]]*bind-addr:[[:space:]]*"\[::\]:([0-9]+)".*/\1/p' "$file" | head -n1
      ;;
  esac
}

update_config() {
  # Only replace the listening port field; do not touch other fields
  local app="$1" newp="$2" file="${CONF[$app]}"
  [[ -f "$file" ]] || die "未找到配置文件：$file"

  case "$app" in
    tuic)
      # "server": "[::]:PORT"
      sed -E -i 's#("server"[[:space:]]*:[[:space:]]*")\[::\]:[0-9]+(")#\1[::]:'"$newp"'\2#' "$file"
      ;;
    shoes)
      # address: "[::]:PORT"   (dash optional)
      sed -E -i 's#(^[[:space:]]*-?[[:space:]]*address:[[:space:]]*")\[::\]:[0-9]+(")#\1[::]:'"$newp"'\2#' "$file"
      ;;
    shadowquic)
      # bind-addr: "[::]:PORT"
      sed -E -i 's#(^[[:space:]]*bind-addr:[[:space:]]*")\[::\]:[0-9]+(")#\1[::]:'"$newp"'\2#' "$file"
      ;;
  esac
}

choose_port() {
  # Presents a dynamic 1..N menu from the current avail_ports array.
  # Returns chosen port in global CHOSEN_PORT and removes it from avail_ports.
  while :; do
    echo -n "  请选择端口： "
    local i=1
    for p in "${avail_ports[@]}"; do
      printf "%d)%d  " "$i" "$p"
      ((i++))
    done
    echo
    read -rp "  输入序号(1-${#avail_ports[@]}): " ans
    [[ "$ans" =~ ^[1-9][0-9]*$ ]] || { echo "  无效输入"; continue; }
    (( ans>=1 && ans<=${#avail_ports[@]} )) || { echo "  超出范围"; continue; }

    local idx=$((ans-1))
    CHOSEN_PORT="${avail_ports[$idx]}"

    # remove chosen index
    local newlist=()
    for j in "${!avail_ports[@]}"; do
      [[ $j -ne $idx ]] && newlist+=("${avail_ports[$j]}")
    done
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

do_install() {
  install -m 0755 "$0" /usr/local/bin/port
  echo "已安装为 /usr/local/bin/port"
}

# ---------- Main ----------
need_root

if [[ "${1:-}" == "--install" ]]; then
  do_install
  exit 0
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_usage
  exit 0
fi

installed=()
echo "=== 检测安装（仅检查 unit+配置是否存在） ==="
for app in "${order[@]}"; do
  if installed_service "$app"; then
    installed+=("$app")
    echo " - ${LABEL[$app]}: 已安装"
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
  oldp="$(current_port "$app")"; oldp="${oldp:-未知}"
  printf " - %-12s: %s -> %s\n" "${LABEL[$app]}" "$oldp" "${chosen[$app]}"
done
read -rp $'按回车执行修改并重启对应服务（Ctrl+C 取消）…'

# Apply changes
for app in "${installed[@]}"; do
  update_config "$app" "${chosen[$app]}"
done

# Reload & restart
systemctl daemon-reload
for app in "${installed[@]}"; do
  restart_service "${UNIT[$app]}"
done

echo "完成。"
