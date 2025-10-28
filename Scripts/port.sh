#!/usr/bin/env bash
# port - one-key port switcher for TUIC / Shoes / ShadowQUIC
# 设计目标：
# - 第一次用：bash <(curl -fsSL https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Scripts/port.sh)
#   → 自动落盘到 /usr/local/sbin/port.sh，并创建启动器 /usr/local/bin/port
#   → 以后直接在 shell 输入：port
# - 仅检测“已安装”（unit+配置同时存在），不检查运行状态/端口占用
# - 端口候选 {443,4443,8443}，被前面选走后从下一轮菜单移除，序号动态重排
# - 仅修改监听端口字段；改完统一 daemon-reload 并重启对应服务

set -euo pipefail

# ---------- 自身安装信息 ----------
SCRIPT_VERSION="1.0.0"
SCRIPT_INSTALL="/usr/local/sbin/port.sh"
SCRIPT_LAUNCHER="/usr/local/bin/port"
SCRIPT_REMOTE_RAW="https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Scripts/port.sh"

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
die(){ echo "Error: $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请用 root 运行"; }

unit_exists() {
  local u="$1"
  [[ -f "/etc/systemd/system/$u" ]] || [[ -f "/lib/systemd/system/$u" ]] || [[ -f "/usr/lib/systemd/system/$u" ]]
}

installed_service() {
  local app="$1"
  unit_exists "${UNIT[$app]}" && [[ -f "${CONF[$app]}" ]]
}

current_port() {
  # 兼容 "[::]:PORT" / "0.0.0.0:PORT" / 任意 "HOST:PORT" / ":PORT"
  local app="$1" file="${CONF[$app]}"
  [[ -f "$file" ]] || { echo ""; return; }
  case "$app" in
    tuic)
      # 例："server": "[::]:443" / "server": "0.0.0.0:443" / "server": ":443"
      sed -nE 's/.*"server"[[:space:]]*:[[:space:]]*"([^"]*):([0-9]+)".*/\2/p' "$file" | head -n1
      ;;
    shoes)
      # 例：- address: "[::]:8443" / "0.0.0.0:8443" / ":8443"
      sed -nE 's/^[[:space:]]*-?[[:space:]]*address:[[:space:]]*"([^"]*):([0-9]+)".*/\2/p' "$file" | head -n1
      ;;
    shadowquic)
      # 例：bind-addr: "[::]:443" / "0.0.0.0:443" / ":443"
      sed -nE 's/^[[:space:]]*bind-addr:[[:space:]]*"([^"]*):([0-9]+)".*/\2/p' "$file" | head -n1
      ;;
  esac
}

update_config() {
  # 仅替换监听端口字段；保留原 host（[::]/0.0.0.0/自定义等）
  local app="$1" newp="$2" file="${CONF[$app]}"
  [[ -f "$file" ]] || die "未找到配置文件：$file"
  case "$app" in
    tuic)
      # 把 "server": "HOST:OLD" → "server": "HOST:NEW"
      sed -E -i 's#("server"[[:space:]]*:[[:space:]]*"[^"]*:)[0-9]+(")#\1'"$newp"'\2#' "$file"
      ;;
    shoes)
      # 把 address: "HOST:OLD" → address: "HOST:NEW"
      sed -E -i 's#(^[[:space:]]*-?[[:space:]]*address:[[:space:]]*"[^"]*:)[0-9]+(")#\1'"$newp"'\2#' "$file"
      ;;
    shadowquic)
      # 把 bind-addr: "HOST:OLD" → bind-addr: "HOST:NEW"
      sed -E -i 's#(^[[:space:]]*bind-addr:[[:space:]]*"[^"]*:)[0-9]+(")#\1'"$newp"'\2#' "$file"
      ;;
  esac
}

choose_port() {
  # 动态编号 1..N；返回 CHOSEN_PORT，并从 avail_ports 中移除
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

restart_service(){ systemctl restart "$1"; }

ensure_launcher() {
  # 将脚本本体落盘到 /usr/local/sbin/port.sh，并写启动器 /usr/local/bin/port
  mkdir -p "$(dirname "$SCRIPT_INSTALL")" "$(dirname "$SCRIPT_LAUNCHER")"
  local self; self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  if [[ "$self" == /proc/*/fd/* || "$self" == /dev/fd/* ]]; then
    # 通过 bash <(curl ...) 运行：从远端拉取一份到固定路径
    curl -fsSL "$SCRIPT_REMOTE_RAW" -o "$SCRIPT_INSTALL"
    chmod +x "$SCRIPT_INSTALL"
  else
    # 本地文件运行：复制自身
    if [[ "$self" != "$SCRIPT_INSTALL" ]]; then
      cp -f "$self" "$SCRIPT_INSTALL"
    fi
    chmod +x "$SCRIPT_INSTALL"
  fi
  cat > "$SCRIPT_LAUNCHER" <<'LAUNCH'
#!/usr/bin/env bash
exec bash /usr/local/sbin/port.sh "$@"
LAUNCH
  chmod +x "$SCRIPT_LAUNCHER"
}

# ---------- 主流程 ----------
need_root
ensure_launcher

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

echo "完成。现在起可直接使用命令：port"
