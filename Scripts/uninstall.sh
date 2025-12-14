#!/usr/bin/env bash
# 完整卸载脚本（不清理依赖，不做备份）
# 覆盖：caddy / xray / sing-box / tuic / juicity / shoes / shadowquic / snell
set -euo pipefail

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行。"
    exit 1
  fi
}

exists_cmd(){ command -v "$1" >/dev/null 2>&1; }

stop_disable_service() {
  local base="$1"
  local svc="${base}.service"

  systemctl unmask "$svc" 2>/dev/null || true
  systemctl unmask "${base}@.service" 2>/dev/null || true

  systemctl stop "$svc" 2>/dev/null || true
  mapfile -t _inst < <(systemctl list-units --all --type=service --no-legend \
                        | awk '{print $1}' | grep -E "^${base}@.+\.service$" || true)
  for u in "${_inst[@]}"; do systemctl stop "$u" 2>/dev/null || true; done

  systemctl disable "$svc" 2>/dev/null || true
  systemctl disable "${base}@.service" 2>/dev/null || true

  find /etc/systemd/system -maxdepth 2 -type l -name "${svc}" -delete 2>/dev/null || true
  find /etc/systemd/system -maxdepth 2 -type l -name "${base}@*.service" -delete 2>/dev/null || true

  systemctl reset-failed "$svc" 2>/dev/null || true
}

remove_unit_artifacts() {
  local base="$1"
  local patterns=(
    "/etc/systemd/system/${base}.service"
    "/etc/systemd/system/${base}.service.d"
    "/etc/systemd/system/${base}@.service"
    "/etc/systemd/system/${base}@.service.d"

    "/lib/systemd/system/${base}.service"
    "/lib/systemd/system/${base}@.service"

    "/usr/lib/systemd/system/${base}.service"
    "/usr/lib/systemd/system/${base}@.service"
  )

  for p in "${patterns[@]}"; do
    [ -e "$p" ] && rm -rf "$p" || true
  done

  find /etc/systemd/system -maxdepth 2 -type l -name "${base}.service" -delete 2>/dev/null || true
  find /etc/systemd/system -maxdepth 2 -type l -name "${base}@*.service" -delete 2>/dev/null || true

  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true
}

remove_paths(){ for p in "$@"; do [ -e "$p" ] && rm -rf "$p" || true; done; }

remove_user_group() {
  local user="$1" group="${2:-$1}"
  local home
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  if id -u "$user" >/dev/null 2>&1; then
    userdel -r "$user" 2>/dev/null || true
  fi
  [ -n "${home:-}" ] && [ -d "$home" ] && rm -rf "$home" || true
  if getent group "$group" >/dev/null 2>&1; then
    groupdel "$group" 2>/dev/null || true
  fi
}

pause() { echo; read -rp "按回车返回主菜单..." _; }

# ---------------- 各组件卸载 ----------------
uninstall_caddy() {
  echo ">>> 卸载 Caddy ..."
  # 常见：caddy / caddy-l4（你的脚本）
  for base in "caddy" "caddy-l4"; do
    stop_disable_service "$base"
    remove_unit_artifacts "$base"
  done
  remove_paths \
    /usr/local/bin/caddy /usr/local/bin/caddy-l4 \
    /etc/caddy /var/lib/caddy /var/log/caddy \
    /usr/local/share/caddy /usr/share/caddy \
    /etc/logrotate.d/caddy /etc/logrotate.d/caddy-l4
  remove_user_group "caddy" || true
  echo "[OK] Caddy 卸载完成。"
}

uninstall_xray() {
  echo ">>> 卸载 Xray ..."
  stop_disable_service "xray"
  remove_unit_artifacts "xray"
  remove_paths \
    /usr/local/bin/xray \
    /etc/xray /var/lib/xray /var/log/xray \
    /usr/local/share/xray /usr/share/xray \
    /etc/logrotate.d/xray
  remove_user_group "xray" || true
  echo "[OK] Xray 卸载完成。"
}

uninstall_singbox() {
  echo ">>> 卸载 sing-box ..."
  for base in "sing-box" "singbox"; do
    stop_disable_service "$base"
    remove_unit_artifacts "$base"
  done
  remove_paths \
    /usr/local/bin/sing-box \
    /etc/sing-box /var/lib/sing-box /var/log/sing-box \
    /etc/logrotate.d/sing-box
  remove_user_group "sing-box" "sing-box" || true
  remove_user_group "singbox" "singbox" || true
  echo "[OK] sing-box 卸载完成。"
}

uninstall_tuic() {
  echo ">>> 卸载 TUIC ..."
  for base in "tuic" "tuic-server"; do
    stop_disable_service "$base"
    remove_unit_artifacts "$base"
  done
  remove_paths \
    /usr/local/bin/tuic /usr/local/bin/tuic-server \
    /etc/tuic /var/lib/tuic /var/log/tuic \
    /etc/logrotate.d/tuic
  remove_user_group "tuic" || true
  echo "[OK] TUIC 卸载完成。"
}

uninstall_juicity() {
  echo ">>> 卸载 Juicity ..."
  for base in "juicity-server" "juicity"; do
    stop_disable_service "$base"
    remove_unit_artifacts "$base"
  done
  remove_paths \
    /usr/local/bin/juicity-server /usr/local/bin/juicity \
    /etc/juicity /var/lib/juicity /var/log/juicity \
    /etc/logrotate.d/juicity
  remove_user_group "juicity" || true
  echo "[OK] Juicity 卸载完成。"
}

uninstall_shoes() {
  echo ">>> 卸载 Shoes ..."
  stop_disable_service "shoes"
  remove_unit_artifacts "shoes"
  remove_paths \
    /usr/local/bin/shoes /usr/local/bin/shoes-server \
    /etc/shoes /var/lib/shoes /var/log/shoes \
    /etc/logrotate.d/shoes
  remove_user_group "shoes" || true
  echo "[OK] Shoes 卸载完成。"
}

uninstall_shadowquic() {
  echo ">>> 卸载 ShadowQUIC ..."
  stop_disable_service "shadowquic"
  remove_unit_artifacts "shadowquic"
  remove_paths \
    /usr/local/bin/shadowquic \
    /etc/shadowquic /var/lib/shadowquic /var/log/shadowquic \
    /etc/logrotate.d/shadowquic
  remove_user_group "shadowquic" || true
  echo "[OK] ShadowQUIC 卸载完成。"
}

uninstall_snell() {
  echo ">>> 卸载 Snell ..."
  for base in "snell" "snell-server"; do
    stop_disable_service "$base"
    remove_unit_artifacts "$base"
  done
  remove_paths \
    /usr/local/bin/snell /usr/local/bin/snell-server \
    /etc/snell /var/lib/snell /var/log/snell \
    /etc/logrotate.d/snell
  remove_user_group "snell" || true
  remove_user_group "snell-server" || true
  echo "[OK] Snell 卸载完成。"
}

uninstall_all() {
  echo ">>> 将卸载所有：Caddy / Xray / sing-box / TUIC / Juicity / Shoes / ShadowQUIC / Snell"
  uninstall_caddy
  uninstall_xray
  uninstall_singbox
  uninstall_tuic
  uninstall_juicity
  uninstall_shoes
  uninstall_shadowquic
  uninstall_snell
  echo "[OK] 所有组件已卸载。"
}

# ---------------- 主菜单循环 ----------------
main_menu() {
  while true; do
    clear
    cat <<'MENU'
================ 卸载菜单 ================
1) 卸载 Caddy (含 caddy-l4)
2) 卸载 Xray
3) 卸载 sing-box
4) 卸载 TUIC
5) 卸载 Juicity
6) 卸载 Shoes
7) 卸载 ShadowQUIC
8) 卸载 Snell
9) 卸载以上所有
0) 退出
=========================================
MENU
    read -rp "请选择 [0-9]: " choice
    echo
    case "${choice:-}" in
      1) uninstall_caddy;      pause ;;
      2) uninstall_xray;       pause ;;
      3) uninstall_singbox;    pause ;;
      4) uninstall_tuic;       pause ;;
      5) uninstall_juicity;    pause ;;
      6) uninstall_shoes;      pause ;;
      7) uninstall_shadowquic; pause ;;
      8) uninstall_snell;      pause ;;
      9) uninstall_all;        pause ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "无效选择"; pause ;;
    esac
  done
}

need_root
exists_cmd systemctl || { echo "需要 systemd 环境"; exit 1; }
main_menu
