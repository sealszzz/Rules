#!/usr/bin/env bash
# 完整卸载脚本（不清理依赖，不做备份）
# 覆盖：hysteria2 / snell / tuic / ss-rust / shoes / shadowquic / xray / sing-box
set -euo pipefail
export LC_ALL=C

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行：sudo $0"
    exit 1
  fi
}

exists_cmd(){ command -v "$1" >/dev/null 2>&1; }

# ========== 共用小工具 ==========
safe_rm(){ rm -rf "$@" 2>/dev/null || true; }

stop_disable_service() {
  # 兼容主 unit 与模板实例；内部关闭 -e，确保不早退
  set +e
  local base="$1" svc="${base}.service"
  echo " - 停止 ${svc}"
  systemctl stop "$svc" >/dev/null 2>&1

  # 模板实例
  mapfile -t _insts < <(systemctl list-units --all --type=service --no-legend 2>/dev/null \
     | awk '{print $1}' | grep -E "^${base}@.+\.service$" 2>/dev/null)
  for u in "${_insts[@]:-}"; do
    [ -n "$u" ] && { echo " - 停止 ${u}"; systemctl stop "$u" >/dev/null 2>&1; }
  done

  echo " - 禁用 ${svc}"
  systemctl disable "$svc" >/dev/null 2>&1

  mapfile -t _tpls < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null \
     | awk '{print $1}' | grep -E "^${base}@\.service$" 2>/dev/null)
  for t in "${_tpls[@]:-}"; do
    [ -n "$t" ] && { echo " - 禁用 ${t}"; systemctl disable "$t" >/dev/null 2>&1; }
  done

  safe_rm "/etc/systemd/system/multi-user.target.wants/${svc}"
  safe_rm /etc/systemd/system/multi-user.target.wants/"${base}"@*.service
  systemctl reset-failed "$svc" >/dev/null 2>&1
  set -e
}

remove_std_units_by_base() {
  set +e
  local base="$1"
  safe_rm \
    "/etc/systemd/system/${base}.service" \
    "/lib/systemd/system/${base}.service" \
    "/usr/lib/systemd/system/${base}.service" \
    "/etc/systemd/system/${base}@.service" \
    "/lib/systemd/system/${base}@.service" \
    "/usr/lib/systemd/system/${base}@.service" \
    "/etc/systemd/system/${base}.service.d" \
    "/etc/systemd/system/${base}@.service.d"
  systemctl daemon-reload >/dev/null 2>&1
  systemctl reset-failed >/dev/null 2>&1
  set -e
}

remove_unit_files() {
  set +e
  for f in "$@"; do [ -e "$f" ] && safe_rm "$f"; done
  systemctl daemon-reload >/dev/null 2>&1
  systemctl reset-failed >/dev/null 2>&1
  set -e
}

remove_paths(){ for p in "$@"; do [ -e "$p" ] && safe_rm "$p"; done; }

remove_user_group() {
  set +e
  local user="$1" group="${2:-$1}"
  local home
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
  id -u "$user" >/dev/null 2>&1 && userdel -r "$user" >/dev/null 2>&1
  [ -n "${home:-}" ] && [ -d "$home" ] && safe_rm "$home"
  getent group "$group" >/dev/null 2>&1 && groupdel "$group" >/dev/null 2>&1
  set -e
}

pause(){ echo; read -rp "按回车返回主菜单..." _; }

# ========== 各组件卸载（老版基线 + 扩展目标） ==========
uninstall_hysteria(){
  echo ">>> 卸载 Hysteria2 ..."
  stop_disable_service "hysteria2"
  stop_disable_service "hysteria-server"
  remove_unit_files \
    /etc/systemd/system/hysteria2.service \
    /etc/systemd/system/hysteria-server.service \
    /etc/systemd/system/hysteria-server@.service
  remove_std_units_by_base "hysteria2"
  remove_std_units_by_base "hysteria-server"
  remove_paths /usr/local/bin/hysteria /etc/hysteria /var/lib/hysteria /var/log/hysteria
  remove_user_group "hysteria"
  remove_user_group "hysteria2"
  echo "[OK] Hysteria2 卸载完成。"
}

uninstall_snell(){
  echo ">>> 卸载 Snell ..."
  stop_disable_service "snell"
  stop_disable_service "snell-server"
  remove_unit_files /etc/systemd/system/snell.service /etc/systemd/system/snell-server.service
  remove_std_units_by_base "snell"
  remove_std_units_by_base "snell-server"
  remove_paths /usr/local/bin/snell-server /usr/local/bin/snell /usr/local/sbin/snell.sh /etc/snell /var/lib/snell /var/log/snell
  remove_user_group "snell"
  remove_user_group "snell-server"
  echo "[OK] Snell 卸载完成。"
}

uninstall_tuic(){
  echo ">>> 卸载 TUIC ..."
  stop_disable_service "tuic-server"
  remove_unit_files /etc/systemd/system/tuic-server.service
  remove_std_units_by_base "tuic-server"
  remove_paths /usr/local/bin/tuic-server /etc/tuic /var/lib/tuic /var/log/tuic
  remove_user_group "tuic"
  echo "[OK] TUIC 卸载完成。"
}

uninstall_ssrust(){
  echo ">>> 卸载 Shadowsocks-Rust ..."
  stop_disable_service "ssrust"
  remove_unit_files /etc/systemd/system/ssrust.service
  remove_std_units_by_base "ssrust"
  remove_paths /usr/local/bin/ssserver /usr/local/sbin/ssrust.sh /usr/local/bin/ssrust /etc/ssrust /var/lib/ssrust /var/log/ssrust
  remove_user_group "ssrust"
  echo "[OK] SSRust 卸载完成。"
}

uninstall_shoes(){
  echo ">>> 卸载 Shoes ..."
  stop_disable_service "shoes"
  remove_unit_files /etc/systemd/system/shoes.service
  remove_std_units_by_base "shoes"
  remove_paths /usr/local/bin/shoes /usr/local/bin/shoes-server /usr/local/bin/shoes.bak.* /etc/shoes /var/lib/shoes /var/log/shoes
  remove_user_group "shoes"
  echo "[OK] Shoes 卸载完成。"
}

uninstall_shadowquic(){
  echo ">>> 卸载 ShadowQUIC ..."
  stop_disable_service "shadowquic"
  remove_unit_files /etc/systemd/system/shadowquic.service
  remove_std_units_by_base "shadowquic"
  remove_paths /usr/local/bin/shadowquic /etc/shadowquic /var/lib/shadowquic /var/log/shadowquic
  remove_user_group "shadowquic"
  echo "[OK] ShadowQUIC 卸载完成。"
}

uninstall_xray(){
  echo ">>> 卸载 Xray ..."
  stop_disable_service "xray"
  remove_unit_files /etc/systemd/system/xray.service
  remove_std_units_by_base "xray"
  remove_paths /usr/local/bin/xray /etc/xray /var/lib/xray /var/log/xray /usr/local/share/xray /etc/logrotate.d/xray
  remove_user_group "xray"
  echo "[OK] Xray 卸载完成。"
}

uninstall_singbox(){
  echo ">>> 卸载 sing-box ..."
  stop_disable_service "sing-box"
  remove_unit_files /etc/systemd/system/sing-box.service
  remove_std_units_by_base "sing-box"
  remove_paths /usr/local/bin/sing-box /etc/sing-box /var/lib/sing-box /var/log/sing-box
  remove_user_group "sing-box"
  echo "[OK] sing-box 卸载完成。"
}

uninstall_all(){
  echo ">>> 将卸载所有：Hysteria2 / Snell / TUIC / SSRust / Shoes / ShadowQUIC / Xray / sing-box"
  uninstall_hysteria
  uninstall_snell
  uninstall_tuic
  uninstall_ssrust
  uninstall_shoes
  uninstall_shadowquic
  uninstall_xray
  uninstall_singbox
  echo "[OK] 所有组件已卸载。"
}

# ========== 菜单（老版交互，新增条目） ==========
main_menu() {
  while true; do
    clear
    cat <<'MENU'
================ 卸载菜单 ================
1) 卸载 Hysteria2
2) 卸载 Snell
3) 卸载 TUIC
4) 卸载 Shadowsocks-Rust (ssrust)
5) 卸载 Shoes
6) 卸载 ShadowQUIC
7) 卸载 Xray
8) 卸载 sing-box
9) 卸载以上所有
0) 退出
=========================================
MENU
    read -rp "请选择 [0-9]: " choice
    echo
    case "${choice:-}" in
      1) uninstall_hysteria;    systemctl daemon-reload >/dev/null 2>&1 || true; pause ;;
      2) uninstall_snell;       systemctl daemon-reload >/dev/null 2>&1 || true; pause ;;
      3) uninstall_tuic;        systemctl daemon-reload >/dev/null 2>&1 || true; pause ;;
      4) uninstall_ssrust;      systemctl daemon-reload >/dev/null 2>&1 || true; pause ;;
      5) uninstall_shoes;       systemctl daemon-reload >/dev/null 2;&1  || true; pause ;;
      6) uninstall_shadowquic;  systemctl daemon-reload >/dev/null 2>&1 || true; pause ;;
      7) uninstall_xray;        systemctl daemon-reload >/dev/null 2>&1 || true; pause ;;
      8) uninstall_singbox;     systemctl daemon-reload >/dev/null 2>&1 || true; pause ;;
      9) uninstall_all;         systemctl daemon-reload >/dev/null 2>&1 || true; pause ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "无效选择"; pause ;;
    esac
  done
}

need_root
exists_cmd systemctl || { echo "需要 systemd 环境"; exit 1; }
main_menu
