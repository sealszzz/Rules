#!/usr/bin/env bash
# 完整卸载脚本（不清理依赖，不做备份）
# 覆盖：hysteria2 / snell / tuic / ss-rust / shoes / shadowquic / xray
set -euo pipefail

# ---------------- 工具函数 ----------------
need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行。"
    exit 1
  fi
}

exists_cmd(){ command -v "$1" >/dev/null 2>&1; }

# 停止并禁用主/模板服务，顺带解 mask、清 wants 残链
stop_disable_service() {
  local base="$1"            # 不带 .service
  local svc="${base}.service"

  # 先解 mask（以免 disable/stop 失败）
  systemctl unmask "$svc" 2>/dev/null || true
  systemctl unmask "${base}@.service" 2>/dev/null || true

  # 停止主服务与所有模板实例
  systemctl stop "$svc" 2>/dev/null || true
  mapfile -t _inst < <(systemctl list-units --all --type=service --no-legend \
                        | awk '{print $1}' | grep -E "^${base}@.+\.service$" || true)
  for u in "${_inst[@]}"; do systemctl stop "$u" 2>/dev/null || true; done

  # 禁用主服务与模板
  systemctl disable "$svc" 2>/dev/null || true
  systemctl disable "${base}@.service" 2>/dev/null || true

  # 清理多种 target 下可能残留的 wants 链接（保险起见全局找）
  find /etc/systemd/system -maxdepth 2 -type l -name "${svc}" -delete 2>/dev/null || true
  find /etc/systemd/system -maxdepth 2 -type l -name "${base}@*.service" -delete 2>/dev/null || true
  
  systemctl reset-failed "$svc" 2>/dev/null || true
}

# 彻底移除单元文件（含 drop-in 目录、/lib 与 /usr/lib 的单元、模板单元）
remove_unit_artifacts() {
  local base="$1"  # 不带 .service
  # 可能存在的路径模式
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

  # 删除主/模板单元与 drop-in 目录
  for p in "${patterns[@]}"; do
    [ -e "$p" ] && rm -rf "$p" || true
  done

  # 兜底再清理 /etc/systemd/system 下所有可能的 wants 残链
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
uninstall_hysteria() {
  echo ">>> 卸载 Hysteria2 ..."
  for base in "hysteria2" "hysteria" "hysteria-server"; do
    stop_disable_service "$base"
    remove_unit_artifacts "$base"
  done
  remove_paths \
    /usr/local/bin/hysteria \
    /etc/hysteria /var/lib/hysteria /var/log/hysteria \
    /etc/logrotate.d/hysteria
  remove_user_group "hysteria" || true
  remove_user_group "hysteria2" || true
  echo "[OK] Hysteria2 卸载完成。"
}

uninstall_snell() {
  echo ">>> 卸载 Snell ..."
  for base in "snell" "snell-server"; do
    stop_disable_service "$base"
    remove_unit_artifacts "$base"
  done
  remove_paths \
    /usr/local/bin/snell /usr/local/bin/snell-server \
    /usr/local/sbin/snell.sh \
    /etc/snell /var/lib/snell /var/log/snell \
    /etc/logrotate.d/snell
  remove_user_group "snell" || true
  remove_user_group "snell-server" || true
  echo "[OK] Snell 卸载完成。"
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

uninstall_ssrust() {
  echo ">>> 卸载 Shadowsocks-Rust ..."
  for base in "ssrust" "ssserver" "shadowsocks-rust"; do
    stop_disable_service "$base"
    remove_unit_artifacts "$base"
  done
  remove_paths \
    /usr/local/bin/ssserver /usr/local/bin/ssrust \
    /usr/local/sbin/ssrust.sh \
    /etc/ssrust /var/lib/ssrust /var/log/ssrust \
    /etc/logrotate.d/ssrust
  remove_user_group "ssrust" || true
  echo "[OK] SSRust 卸载完成。"
}

uninstall_shoes() {
  echo ">>> 卸载 Shoes ..."
  stop_disable_service "shoes"
  remove_unit_artifacts "shoes"   # ★ 会删除 /etc/systemd/system/shoes.service.d/
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

uninstall_all() {
  echo ">>> 将卸载所有：Hysteria2 / Snell / TUIC / SSRust / Shoes / ShadowQUIC / Xray"
  uninstall_hysteria
  uninstall_snell
  uninstall_tuic
  uninstall_ssrust
  uninstall_shoes
  uninstall_shadowquic
  uninstall_xray
  echo "[OK] 所有组件已卸载。"
}

# ---------------- 主菜单循环 ----------------
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
8) 卸载以上所有
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
      8) uninstall_all;         pause ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "无效选择"; pause ;;
    esac
  done
}

need_root
exists_cmd systemctl || { echo "需要 systemd 环境"; exit 1; }
main_menu
