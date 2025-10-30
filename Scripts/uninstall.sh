#!/usr/bin/env bash
set -euo pipefail

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行：sudo $0"
    exit 1
  fi
}

exists_cmd(){ command -v "$1" >/dev/null 2>&1; }

safe_rm(){ rm -rf -- "$@" 2>/dev/null || true; }

stop_disable_service() {
  local base="$1"
  local svc="${base}.service"

  systemctl stop "$svc" 2>/dev/null || true

  local units=()
  mapfile -t units < <(
    systemctl list-units --all --type=service --no-legend 2>/dev/null \
      | awk '{print $1}' | grep -E "^${base}@.+\.service$" || true
  )
  for u in "${units[@]}"; do
    systemctl stop "$u" 2>/dev/null || true
  done

  systemctl disable "$svc" 2>/dev/null || true

  local tpls=()
  mapfile -t tpls < <(
    systemctl list-unit-files --type=service --no-legend 2>/dev/null \
      | awk '{print $1}' | grep -E "^${base}@\.service$" || true
  )
  for t in "${tpls[@]}"; do
    systemctl disable "$t" 2>/dev/null || true
  done
  
  safe_rm "/etc/systemd/system/multi-user.target.wants/${svc}"
  safe_rm /etc/systemd/system/multi-user.target.wants/"${base}"@*.service

  systemctl reset-failed "$svc" 2>/dev/null || true
}

remove_unit_files() {
  local base="$1"

  safe_rm \
    "/etc/systemd/system/${base}.service" \
    "/lib/systemd/system/${base}.service" \
    "/usr/lib/systemd/system/${base}.service"

  safe_rm \
    "/etc/systemd/system/${base}@.service" \
    "/lib/systemd/system/${base}@.service" \
    "/usr/lib/systemd/system/${base}@.service"
  safe_rm \
    "/etc/systemd/system/${base}.service.d" \
    "/etc/systemd/system/${base}@.service.d"

  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true
}

remove_paths() { for p in "$@"; do [ -e "$p" ] && safe_rm "$p"; done; }

remove_user_group() {
  local user="$1" group="${2:-$1}"
  local home; home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  if id -u "$user" >/dev/null 2>&1; then
    userdel -r "$user" 2>/dev/null || true
  fi
  [ -n "${home:-}" ] && [ -d "$home" ] && safe_rm "$home"
  getent group "$group" >/dev/null 2>&1 && groupdel "$group" 2>/dev/null || true
}

pause() { echo; read -rp "按回车返回主菜单..." _; }

# Hysteria2
uninstall_hysteria() {
  echo ">>> 卸载 Hysteria2 ..."
  stop_disable_service "hysteria-server"
  stop_disable_service "hysteria2"
  remove_unit_files "hysteria-server"
  remove_unit_files "hysteria2"
  remove_paths \
    /usr/local/bin/hysteria \
    /etc/hysteria \
    /var/lib/hysteria
  remove_user_group "hysteria"
  remove_user_group "hysteria2"
  echo "[OK] Hysteria2 卸载完成。"
}

# Snell
uninstall_snell() {
  echo ">>> 卸载 Snell ..."
  stop_disable_service "snell"
  stop_disable_service "snell-server"
  remove_unit_files "snell"
  remove_unit_files "snell-server"
  remove_paths \
    /usr/local/bin/snell-server \
    /usr/local/sbin/snell.sh \
    /usr/local/bin/snell \
    /etc/snell \
    /var/lib/snell
  remove_user_group "snell"
  remove_user_group "snell-server"
  echo "[OK] Snell 卸载完成。"
}

# TUIC
uninstall_tuic() {
  echo ">>> 卸载 TUIC ..."
  stop_disable_service "tuic-server"
  remove_unit_files "tuic-server"
  remove_paths \
    /usr/local/bin/tuic-server \
    /etc/tuic \
    /var/lib/tuic
  remove_user_group "tuic"
  echo "[OK] TUIC 卸载完成。"
}

# Shadowsocks-Rust
uninstall_ssrust() {
  echo ">>> 卸载 Shadowsocks-Rust ..."
  stop_disable_service "ssrust"
  remove_unit_files "ssrust"
  remove_paths \
    /usr/local/bin/ssserver \
    /usr/local/sbin/ssrust.sh \
    /usr/local/bin/ssrust \
    /etc/ssrust \
    /var/lib/ssrust
  remove_user_group "ssrust"
  echo "[OK] SSRust 卸载完成。"
}

# Shoes
uninstall_shoes() {
  echo ">>> 卸载 Shoes ..."
  stop_disable_service "shoes"
  remove_unit_files "shoes"
  remove_paths \
    /usr/local/bin/shoes \
    /usr/local/bin/shoes.bak.* \
    /etc/shoes \
    /var/lib/shoes
  remove_user_group "shoes"
  echo "[OK] Shoes 卸载完成。"
}

# ShadowQUIC
uninstall_shadowquic() {
  echo ">>> 卸载 ShadowQUIC ..."
  stop_disable_service "shadowquic"
  remove_unit_files "shadowquic"
  remove_paths \
    /usr/local/bin/shadowquic \
    /etc/shadowquic \
    /var/lib/shadowquic
  remove_user_group "shadowquic"
  echo "[OK] ShadowQUIC 卸载完成。"
}

# Xray
uninstall_xray() {
  echo ">>> 卸载 Xray ..."
  stop_disable_service "xray"
  remove_unit_files "xray"
  remove_paths \
    /usr/local/bin/xray \
    /etc/xray \
    /var/lib/xray \
    /var/log/xray \
    /usr/local/share/xray \
    /etc/logrotate.d/xray
  remove_user_group "xray"
  echo "[OK] Xray 卸载完成。"
}

# sing-box
uninstall_singbox() {
  echo ">>> 卸载 sing-box ..."
  stop_disable_service "sing-box"
  remove_unit_files "sing-box"
  remove_paths \
    /usr/local/bin/sing-box \
    /etc/sing-box \
    /var/lib/sing-box \
    /var/log/sing-box
  remove_user_group "sing-box"
  echo "[OK] sing-box 卸载完成。"
}

# All uninstall
uninstall_all() {
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
      1) uninstall_hysteria;    pause ;;
      2) uninstall_snell;       pause ;;
      3) uninstall_tuic;        pause ;;
      4) uninstall_ssrust;      pause ;;
      5) uninstall_shoes;       pause ;;
      6) uninstall_shadowquic;  pause ;;
      7) uninstall_xray;        pause ;;
      8) uninstall_singbox;     pause ;;
      9) uninstall_all;         pause ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "无效选择"; pause ;;
    esac
  done
}

need_root
exists_cmd systemctl || { echo "需要 systemd 环境"; exit 1; }
main_menu
