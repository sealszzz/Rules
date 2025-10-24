#!/usr/bin/env bash
# 完整卸载脚本（不清理依赖，不做备份）
# 覆盖：hysteria2 / snell / tuic / ss-rust / shoes
set -u -o pipefail

# ----- 工具函数 -----
need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行：sudo $0"
    exit 1
  fi
}

exists_cmd(){ command -v "$1" >/dev/null 2>&1; }

stop_disable_service() {
  local base="$1"   # 不带 .service 的基名
  local svc="${base}.service"

  # 停止主服务
  systemctl stop "$svc" 2>/dev/null || true
  # 停止模板实例（如 hysteria-server@xxx.service）
  systemctl list-units --all --type=service --no-legend \
    | awk '{print $1}' | grep -E "^${base}@.+\.service$" \
    | while read -r u; do systemctl stop "$u" 2>/dev/null || true; done

  # 禁用主服务与模板
  systemctl disable "$svc" 2>/dev/null || true
  systemctl list-unit-files --type=service --no-legend \
    | awk '{print $1}' | grep -E "^${base}@.+\.service$" \
    | while read -r uf; do systemctl disable "$uf" 2>/dev/null || true; done

  # 清理 wants 目录中的残留软链
  rm -f "/etc/systemd/system/multi-user.target.wants/${svc}" 2>/dev/null || true
  rm -f /etc/systemd/system/multi-user.target.wants/"${base}"@*.service 2>/dev/null || true
}

remove_unit_files() {
  # 传入若干 unit 的完整路径
  for f in "$@"; do
    [ -e "$f" ] && rm -f "$f" || true
  done
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true
}

remove_paths() { for p in "$@"; do [ -e "$p" ] && rm -rf "$p" || true; done; }

remove_user_group() {
  local user="$1" group="${2:-$1}"
  # 先拿 home，便于兜底清理
  local home
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  # 删用户（包含家目录）
  if id -u "$user" >/dev/null 2>&1; then
    userdel -r "$user" 2>/dev/null || true
  fi
  # 兜底清理 home
  [ -n "${home:-}" ] && [ -d "$home" ] && rm -rf "$home" || true
  # 删组
  if getent group "$group" >/dev/null 2>&1; then
    groupdel "$group" 2>/dev/null || true
  fi
}

pause() { echo; read -rp "按回车返回主菜单..." _; }

# ===== Hysteria2 =====
uninstall_hysteria() {
  echo ">>> 卸载 Hysteria2 ..."
  stop_disable_service "hysteria-server"
  remove_unit_files \
    /etc/systemd/system/hysteria-server.service \
    /etc/systemd/system/hysteria-server@.service
  remove_paths \
    /usr/local/bin/hysteria \
    /etc/hysteria \
    /var/lib/hysteria
  remove_user_group "hysteria"
  echo "[OK] Hysteria2 卸载完成。"
}

# ===== Snell =====
uninstall_snell() {
  echo ">>> 卸载 Snell ..."
  stop_disable_service "snell"
  remove_unit_files /etc/systemd/system/snell.service
  remove_paths \
    /usr/local/bin/snell-server \
    /usr/local/sbin/snell.sh \
    /usr/local/bin/snell \
    /etc/snell \
    /var/lib/snell
  remove_user_group "snell"
  echo "[OK] Snell 卸载完成。"
}

# ===== TUIC =====
uninstall_tuic() {
  echo ">>> 卸载 TUIC ..."
  stop_disable_service "tuic-server"
  remove_unit_files /etc/systemd/system/tuic-server.service
  remove_paths \
    /usr/local/bin/tuic-server \
    /etc/tuic \
    /var/lib/tuic
  remove_user_group "tuic"
  echo "[OK] TUIC 卸载完成。"
}

# ===== Shadowsocks-Rust =====
uninstall_ssrust() {
  echo ">>> 卸载 Shadowsocks-Rust ..."
  stop_disable_service "ssrust"
  remove_unit_files /etc/systemd/system/ssrust.service
  remove_paths \
    /usr/local/bin/ssserver \
    /usr/local/sbin/ssrust.sh \
    /usr/local/bin/ssrust \
    /etc/ssrust \
    /var/lib/ssrust
  remove_user_group "ssrust"
  echo "[OK] SSRust 卸载完成。"
}

# ===== Shoes =====
uninstall_shoes() {
  echo ">>> 卸载 Shoes ..."
  stop_disable_service "shoes"
  remove_unit_files /etc/systemd/system/shoes.service
  remove_paths \
    /usr/local/bin/shoes \
    /usr/local/bin/shoes.bak.* \
    /etc/shoes \
    /var/lib/shoes
  remove_user_group "shoes"
  echo "[OK] Shoes 卸载完成。"
}

# ===== 卸载所有 =====
uninstall_all() {
  echo ">>> 将卸载所有：Hysteria2 / Snell / TUIC / SSRust / Shoes"
  # 如需确认，取消下面注释：
  # read -rp "确认卸载全部？[y/N] " ans; [[ "${ans:-N}" =~ ^[Yy]$ ]] || { echo "已取消。"; return; }
  uninstall_hysteria
  uninstall_snell
  uninstall_tuic
  uninstall_ssrust
  uninstall_shoes
  echo "[OK] 所有组件已卸载。"
}

# ----- 主菜单循环 -----
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
6) 卸载以上所有
0) 退出
=========================================
MENU
    read -rp "请选择 [0-6]: " choice
    echo
    case "${choice:-}" in
      1) uninstall_hysteria; pause ;;
      2) uninstall_snell;    pause ;;
      3) uninstall_tuic;     pause ;;
      4) uninstall_ssrust;   pause ;;
      5) uninstall_shoes;    pause ;;
      6) uninstall_all;      pause ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "无效选择"; pause ;;
    esac
  done
}

need_root
exists_cmd systemctl || { echo "需要 systemd 环境"; exit 1; }
main_menu
