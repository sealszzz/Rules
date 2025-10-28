#!/usr/bin/env bash
# 1) 写入脚本
cat >/usr/local/bin/port <<'EOF'
#!/usr/bin/env bash
# port - one-key port switcher for TUIC / Shoes / ShadowQUIC
# - 仅检测“已安装”（unit+配置），不查运行状态/端口占用
# - 每个已安装服务从 {443,4443,8443} 动态菜单选端口（已被占用的从菜单移除、序号重排）
# - 仅改监听端口字段；改完统一 daemon-reload 并重启对应服务

set -euo pipefail

# ---------- 端口候选 ----------
avail_ports=(443 4443 8443)

# ---------- 服务元数据 ----------
declare -A LABEL CONF UNIT
LABEL[tuic]="TUIC"
CONF[tuic]="/etc/tuic/config.json"
UNIT[tuic]="tuic-server.service"

LABEL[shoes]="Shoes"
CONF[shoes]="/etc/shoes/config.yml"
UNIT[shoes]="shoes.service"

LABEL[shadowquic]="ShadowQUIC"
CONF[shadowquic]="/etc/shadowquic/server.yaml"
UNIT[shadowquic]="shadowquic.service"

# 交互顺序
order=(tuic shoes shadowquic)

# ---------- 工具函数 ----------
die() { echo "Error: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "必须以 root 运行。"; }

unit_exists() {
  # 在常见的三处目录里找 unit（兼容不同发行版/安装方式）
  local u="$1"
  [[ -f "/etc/systemd/system/$u" ]] || [[ -f "/lib/systemd/system/$u" ]] || [[ -f "/usr/lib/systemd/system/$u" ]]
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
      # - address: "[::]:8443"
      sed -nE 's/^[[:space:]]*-?[[:space:]]*address:[[:space:]]*"\[::\]:([0-9]+)".*/\1/p' "$file" | head -n1
      ;;
    shadowquic)
      # bind-addr: "[::]:443"
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
  # 根据当前 avail_ports 动态编号 1..N，返回 CHOSEN_PORT，并从 avail_ports 移除
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

    # 删除已选项
    local newlist=()
    for j in "${!avail_ports[@]}"; do
      [[ $j -ne $idx ]] && newlist+=("${avail_ports[$j]}")
    done
    avail_ports=("${newlist[@]}")
    return 0
  done
}

restart_service() {
  local unit="$1"
  systemctl restart "$unit"
}

print_usage() {
  cat <<USAGE
port - TUIC / Shoes / ShadowQUIC 端口切换工具
用法：
  port             进入交互式向导
  port --install   安装为 /usr/local/bin/port （你当前就是这样运行的）
USAGE
}

do_install() {
  install -m 0755 "$0" /usr/local/bin/port
  echo "已安装为 /usr/local/bin/port"
}

# ---------- 主流程 ----------
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
EOF

# 2) 赋权并刷新 shell 的可执行哈希
chmod +x /usr/local/bin/port
hash -r
