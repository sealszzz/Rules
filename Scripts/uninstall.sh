#!/usr/bin/env bash
# 完整卸载脚本（不清理依赖、不做备份）
# 覆盖：xray / tuic / shadowquic / shoes / hysteria2 / snell / sing-box
set -euo pipefail

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "请用 root 运行"; exit 1; }; }
exists_cmd(){ command -v "$1" >/dev/null 2>&1; }

# ---- systemd 停止/禁用（含模板实例，安全防早退）----
stop_disable_unit(){
  local base="$1"                 # 不带 .service 的基名
  local svc="${base}.service"

  # 1) 停止主服务
  systemctl stop "$svc" 2>/dev/null || true

  # 2) 停止模板实例（如 xxx@name.service）
  local insts=()
  mapfile -t insts < <(systemctl list-units --all --type=service --no-legend \
                        | awk '{print $1}' | grep -E "^${base}@.+\.service$" || true)
  for inst in "${insts[@]:-}"; do
    systemctl stop "$inst" 2>/dev/null || true
  done

  # 3) 禁用主/模板服务
  systemctl disable "$svc" 2>/dev/null || true
  local tmpls=()
  mapfile -t tmpls < <(systemctl list-unit-files --type=service --no-legend \
                        | awk '{print $1}' | grep -E "^${base}@\.service$" || true)
  for t in "${tmpls[@]:-}"; do
    systemctl disable "$t" 2>/dev/null || true
  done

  # 4) reset-failed
  systemctl reset-failed "$svc" 2>/dev/null || true

  # 5) 清理 wants 残链（补齐老脚本优点）
  rm -f "/etc/systemd/system/multi-user.target.wants/${svc}" 2>/dev/null || true
  rm -f /etc/systemd/system/multi-user.target.wants/"${base}"@*.service 2>/dev/null || true
}

# ---- 删除 unit 文件（含模板、drop-in）----
rm_units(){
  local base="$1"
  local paths=(
    "/etc/systemd/system/${base}.service"
    "/lib/systemd/system/${base}.service"
    "/usr/lib/systemd/system/${base}.service"
    "/etc/systemd/system/${base}@.service"
    "/lib/systemd/system/${base}@.service"
    "/usr/lib/systemd/system/${base}@.service"
  )
  for f in "${paths[@]}"; do rm -f "$f" 2>/dev/null || true; done
  rm -rf "/etc/systemd/system/${base}.service.d" "/etc/systemd/system/${base}@.service.d" 2>/dev/null || true
}

# ---- 尝试删除系统用户/组（若存在）----
del_user_group(){
  local user="$1" group="$2"
  getent passwd "$user" >/dev/null 2>&1 && userdel -r "$user" 2>/dev/null || true
  getent group  "$group" >/dev/null 2>&1 && groupdel    "$group" 2>/dev/null || true
}

# ---- 通用删路径 ----
rm_paths(){
  local p
  for p in "$@"; do
    [ -e "$p" ] && rm -rf "$p"
  done
}

# ================= 每个软件的卸载实现 =================

uninstall_xray(){
  echo "[Xray] 停止并禁用..."
  stop_disable_unit "xray"

  echo "[Xray] 删除文件..."
  rm_units "xray"
  rm_paths \
    /usr/local/bin/xray \
    /etc/xray /var/lib/xray \
    /var/log/xray \
    /usr/local/share/xray \
    /etc/logrotate.d/xray

  echo "[Xray] 删除用户/组..."
  del_user_group "xray" "xray"
}

uninstall_tuic(){
  echo "[TUIC] 停止并禁用..."
  stop_disable_unit "tuic-server"

  echo "[TUIC] 删除文件..."
  rm_units "tuic-server"
  rm_paths \
    /usr/local/bin/tuic-server \
    /etc/tuic /var/lib/tuic

  echo "[TUIC] 删除用户/组..."
  del_user_group "tuic" "tuic"
}

uninstall_shadowquic(){
  echo "[ShadowQUIC] 停止并禁用..."
  stop_disable_unit "shadowquic"

  echo "[ShadowQUIC] 删除文件..."
  rm_units "shadowquic"
  rm_paths \
    /usr/local/bin/shadowquic \
    /etc/shadowquic /var/lib/shadowquic

  echo "[ShadowQUIC] 删除用户/组..."
  del_user_group "shadowquic" "shadowquic"
}

uninstall_shoes(){
  echo "[Shoes] 停止并禁用..."
  stop_disable_unit "shoes"

  echo "[Shoes] 删除文件..."
  rm_units "shoes"
  rm_paths \
    /usr/local/bin/shoes /usr/local/bin/shoes-server \
    /etc/shoes /var/lib/shoes

  echo "[Shoes] 删除用户/组..."
  del_user_group "shoes" "shoes"
}

uninstall_hysteria2(){
  echo "[Hysteria2] 停止并禁用..."
  # 兼容：hysteria2.service / hysteria-server@.service
  stop_disable_unit "hysteria2"
  stop_disable_unit "hysteria-server"

  echo "[Hysteria2] 删除文件..."
  rm_units "hysteria2"
  rm_units "hysteria-server"
  rm_paths \
    /usr/local/bin/hysteria \
    /etc/hysteria /var/lib/hysteria

  echo "[Hysteria2] 删除用户/组..."
  del_user_group "hysteria" "hysteria" || true
  del_user_group "hysteria2" "hysteria2" || true
}

uninstall_snell(){
  echo "[Snell] 停止并禁用..."
  stop_disable_unit "snell"
  stop_disable_unit "snell-server"

  echo "[Snell] 删除文件..."
  rm_units "snell"
  rm_units "snell-server"
  rm_paths \
    /usr/local/bin/snell /usr/local/bin/snell-server \
    /etc/snell /var/lib/snell

  echo "[Snell] 删除用户/组..."
  del_user_group "snell" "snell" || true
  del_user_group "snell-server" "snell-server" || true
}

uninstall_singbox(){
  echo "[sing-box] 停止并禁用..."
  stop_disable_unit "sing-box"

  echo "[sing-box] 删除文件..."
  rm_units "sing-box"
  rm_paths \
    /usr/local/bin/sing-box \
    /etc/sing-box /var/lib/sing-box

  echo "[sing-box] 删除用户/组..."
  del_user_group "sing-box" "sing-box"
}

uninstall_all(){
  uninstall_xray
  uninstall_tuic
  uninstall_shadowquic
  uninstall_shoes
  uninstall_hysteria2
  uninstall_snell
  uninstall_singbox
}

# ================= 菜单 =================

pause(){ read -rp "按回车返回主菜单..." _; }

main_menu(){
  while :; do
    clear
    cat <<'MENU'
============ 代理组件卸载菜单 ============
 1) 卸载 Xray
 2) 卸载 TUIC
 3) 卸载 ShadowQUIC
 4) 卸载 Shoes
 5) 卸载 Hysteria2
 6) 卸载 Snell
 7) 卸载 sing-box
 8) 卸载以上全部
 0) 退出
=========================================
MENU
    read -rp "选择操作: " ans
    case "${ans:-}" in
      1) uninstall_xray;       systemctl daemon-reload; echo "Xray 已卸载。";       pause ;;
      2) uninstall_tuic;       systemctl daemon-reload; echo "TUIC 已卸载。";       pause ;;
      3) uninstall_shadowquic; systemctl daemon-reload; echo "ShadowQUIC 已卸载。"; pause ;;
      4) uninstall_shoes;      systemctl daemon-reload; echo "Shoes 已卸载。";      pause ;;
      5) uninstall_hysteria2;  systemctl daemon-reload; echo "Hysteria2 已卸载。";  pause ;;
      6) uninstall_snell;      systemctl daemon-reload; echo "Snell 已卸载。";      pause ;;
      7) uninstall_singbox;    systemctl daemon-reload; echo "sing-box 已卸载。";   pause ;;
      8) uninstall_all;        systemctl daemon-reload; echo "全部已卸载。";        pause ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "无效选择"; sleep 1 ;;
    esac
  done
}

# 入口
need_root
exists_cmd systemctl || { echo "需要 systemd 环境"; exit 1; }
main_menu
