#!/usr/bin/env bash
# port - one-key port switcher for TUIC / Shoes / ShadowQUIC
# - 自动落盘 /usr/local/sbin/port.sh，并创建 /usr/local/bin/port
# - 支持 Shoes 同一配置里出现多个监听块：每个监听单独显示/单独改端口
# - 仅修改监听端口字段；改完统一 daemon-reload，并对去重后的 unit 重启一次
set -euo pipefail

# ---------- 自身安装信息 ----------
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

# ----- Shoes 解析：列出每个监听的 index / type / port -----
# 输出行格式： index \t type \t port
shoes_enumerate() {
  local file="${CONF[shoes]}"
  [[ -f "$file" ]] || return 0
  awk '
  BEGIN { idx=0; inprot=0 }
  /^[ \t]*-[ \t]*address:[ \t]*/ {
    idx++
    inprot=0
    line=$0
    # 切下 address: 之后的部分
    sub(/.*address:[ \t]*/, "", line)
    # 去掉注释与尾部空白；若以引号开头，仅取到下一个引号
    if (line ~ /^"/) { sub(/^"/, "", line); sub(/".*$/, "", line) } else { sub(/[ \t]*#.*/, "", line); sub(/[ \t]+$/, "", line) }
    # 提取端口：取最后一个冒号后的字段
    n=split(line, a, ":"); p=""
    if (n>=2) {
      p=a[n]; gsub(/[ \t\r\n]/, "", p)
    }
    port[idx]=p
    type[idx]="unknown"
    next
  }
  /^[ \t]*protocol:[ \t]*$/ { inprot=1; next }
  inprot && /^[ \t]*type:[ \t]*/ {
    t=$0; sub(/^[ \t]*type:[ \t]*/, "", t)
    gsub(/"/, "", t); gsub(/^[ \t]+|[ \t]+$/, "", t)
    type[idx]=t; inprot=0; next
  }
  END {
    for (i=1; i<=idx; i++) {
      if (port[i] == "") port[i] = "未知"
      if (type[i] == "") type[i] = "unknown"
      printf "%d\t%s\t%s\n", i, type[i], port[i]
    }
  }' "$file"
}

# ----- 当前端口读取（按条目） -----
current_port_tuic() {
  sed -nE 's/.*"server"[[:space:]]*:[[:space:]]*"[^"]*:([0-9]+)".*/\1/p' "$1" | head -n1
}
current_port_shadowquic() {
  # 支持可选引号
  sed -nE 's/^[[:space:]]*bind-addr:[[:space:]]*"?[^"]*:([0-9]+)"?.*/\1/p' "$1" | head -n1
}
current_port_shoes_n() {
  local n="$1" file="${CONF[shoes]}"
  shoes_enumerate | awk -F'\t' -v N="$n" '$1==N{print $3; exit}'
}

# ----- 写回（仅改端口；Shoes 支持“第 N 个” address 定点替换） -----
update_config() {
  local app="$1" newp="$2" index="${3:-}" file="${CONF[$app]}"
  [[ -f "$file" ]] || die "未找到配置文件：$file"
  case "$app" in
    tuic)
      sed -E -i 's#("server"[[:space:]]*:[[:space:]]*"[^"]*:)[0-9]+(")#\1'"$newp"'\2#' "$file"
      ;;
    shadowquic)
      sed -E -i 's#(^[[:space:]]*bind-addr:[[:space:]]*"?)([^"]*):[0-9]+("?)(.*)$#\1\2:'"$newp"'\3\4#' "$file"
      ;;
    shoes)
      [[ "$index" =~ ^[0-9]+$ ]] || die "缺少 Shoes 的监听序号"
      awk -v N="$index" -v NEWP="$newp" '
      BEGIN{cnt=0}
      /^[ \t]*-[ \t]*address:[ \t]*/ {
        cnt++
        if (cnt==N) {
          line=$0
          pre=line
          # 定位到 address: 末尾，得到前缀
          if (match(line, /address:[ \t]*/)) {
            pre = substr(line, 1, RSTART+RLENGTH-1)
            rest = substr(line, RSTART+RLENGTH)
          } else { rest=line }
          q = 0
          if (rest ~ /^"/) { q=1; sub(/^"/, "", rest); sub(/".*$/, "", rest) } else { sub(/[ \t]*#.*/, "", rest); sub(/[ \t]+$/, "", rest) }
          n=split(rest, a, ":"); host=""
          if (n>=2) {
            for (i=1; i<n; i++) { if (i>1) host=host ":"; host=host a[i] }
          } else { host=rest }
          if (q) printf "%s\"%s:%s\"\n", pre, host, NEWP
          else   printf "%s%s:%s\n",    pre, host, NEWP
          next
        }
      }
      { print }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
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

ensure_launcher() {
  mkdir -p "$(dirname "$SCRIPT_INSTALL")" "$(dirname "$SCRIPT_LAUNCHER")"
  local self; self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  if [[ "$self" == /proc/*/fd/* || "$self" == /dev/fd/* ]]; then
    curl -fsSL "$SCRIPT_REMOTE_RAW" -o "$SCRIPT_INSTALL"
    chmod +x "$SCRIPT_INSTALL"
  else
    if [[ "$self" != "$SCRIPT_INSTALL" ]]; then cp -f "$self" "$SCRIPT_INSTALL"; fi
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

# 构建条目列表：每个监听都是一个条目
ITEM_LABEL=()   # 展示名
ITEM_APP=()     # tuic / shoes / shadowquic
ITEM_IDX=()     # shoes 的第 N 个监听；其它为空
ITEM_UNIT=()    # 对应需要重启的 unit
ITEM_CURP=()    # 当前端口

# TUIC
if installed_service "tuic"; then
  cur="$(current_port_tuic "${CONF[tuic]}")"; [[ -z "$cur" ]] && cur="未知"
  ITEM_LABEL+=("TUIC")
  ITEM_APP+=("tuic")
  ITEM_IDX+=("")
  ITEM_UNIT+=("${UNIT[tuic]}")
  ITEM_CURP+=("$cur")
fi

# Shoes（多监听）
if installed_service "shoes"; then
  mapfile -t SH_LINES < <(shoes_enumerate)
  if ((${#SH_LINES[@]})); then
    for line in "${SH_LINES[@]}"; do
      idx="${line%%$'\t'*}"; rest="${line#*$'\t'}"
      type="${rest%%$'\t'*}"; port="${rest##*$'\t'}"; [[ -z "$port" ]] && port="未知"
      ITEM_LABEL+=("Shoes: ${type:-unknown} (#${idx})")
      ITEM_APP+=("shoes")
      ITEM_IDX+=("$idx")
      ITEM_UNIT+=("${UNIT[shoes]}")
      ITEM_CURP+=("$port")
    done
  else
    cur="$(current_port_shoes_n 1)"; [[ -z "$cur" ]] && cur="未知"
    ITEM_LABEL+=("Shoes (#1)")
    ITEM_APP+=("shoes")
    ITEM_IDX+=("1")
    ITEM_UNIT+=("${UNIT[shoes]}")
    ITEM_CURP+=("$cur")
  fi
fi

# ShadowQUIC
if installed_service "shadowquic"; then
  cur="$(current_port_shadowquic "${CONF[shadowquic]}")"; [[ -z "$cur" ]] && cur="未知"
  ITEM_LABEL+=("ShadowQUIC")
  ITEM_APP+=("shadowquic")
  ITEM_IDX+=("")
  ITEM_UNIT+=("${UNIT[shadowquic]}")
  ITEM_CURP+=("$cur")
fi

# 没发现条目就退出
((${#ITEM_LABEL[@]})) || { echo "未发现可管理的服务，退出。"; exit 0; }

echo "=== 检测到的监听条目 ==="
for i in "${!ITEM_LABEL[@]}"; do
  printf " %2d) %-22s  (当前端口: %s)\n" "$((i+1))" "${ITEM_LABEL[$i]}" "${ITEM_CURP[$i]}"
done
echo

# 逐条选择端口（端口不足时提示）
declare -A chosen_port
for i in "${!ITEM_LABEL[@]}"; do
  if ((${#avail_ports[@]}==0)); then
    echo "可选端口已用尽，剩余条目将跳过。"
    break
  fi
  echo "为 ${ITEM_LABEL[$i]} 选择端口："
  choose_port
  chosen_port["$i"]="$CHOSEN_PORT"
done

echo
echo "=== 将要应用的修改（仅监听端口字段） ==="
for i in "${!chosen_port[@]}"; do
  oldp="${ITEM_CURP[$i]}"
  newp="${chosen_port[$i]}"
  printf " - %-22s: %s -> %s\n" "${ITEM_LABEL[$i]}" "$oldp" "$newp"
done

# 确认：回车默认 Y；只接受大小写 Y/N
while :; do
  read -rp $'确认应用修改并重启对应服务？[Y/n] ' ans
  ans="${ans:-Y}"
  case "$ans" in
    [Yy]) break ;;
    [Nn]) echo "已取消，不做更改。"; exit 0 ;;
    *) echo "只接受 Y/n（回车默认Y）。";;
  esac
done

# 写回配置（避免 set -u 下缺失下标崩溃）
for i in "${!chosen_port[@]}"; do
  [[ -v ITEM_APP[$i] ]]  || { echo "索引异常：$i（跳过）"; continue; }
  app="${ITEM_APP[$i]}"
  idx="${ITEM_IDX[$i]-}"
  update_config "$app" "${chosen_port[$i]}" "${idx}"
done

# 统一重启（unit 去重，同样做存在性判断）
declare -A uniq_unit
for i in "${!chosen_port[@]}"; do
  [[ -v ITEM_UNIT[$i] ]] || continue
  uniq_unit["${ITEM_UNIT[$i]}"]=1
done
systemctl daemon-reload
for u in "${!uniq_unit[@]}"; do systemctl restart "$u"; done

echo "完成。现在起可直接使用命令：port"
