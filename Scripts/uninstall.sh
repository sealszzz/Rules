#!/usr/bin/env bash
# 完整卸载脚本（不清理依赖，不做备份）
# 覆盖：hysteria2 / snell / tuic / ss-rust / shoes / shadowquic / xray / sing-box / v2ray
set -euo pipefail

# ----- 工具函数（保持你原样风格，增加少量能力）-----
need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行：sudo $0"
    exit 1
  fi
}

exists_cmd(){ command -v "$1" >/dev/null 2>&1; }

# 停止/禁用主 unit + 模板实例，并清 wants 残链
stop_disable_service() {
  local base="$1"
  local svc="${base}.service"

  systemctl stop "$svc" 2>/dev/null || true

  # 停模板实例 base@xxx.service
  local units=()
  mapfile -t units < <(
    systemctl list-units --all --type=service --no-legend \
      | awk '{print $1}' | grep -E "^${base}@.+\.service$" || true
  )
  for u in "${units[@]}"; do
    systemctl stop "$u" 2>/dev/null || true
  done

  systemctl disable "$svc" 2>/dev/null || true

  # 禁用模板单元文件
  local unitfiles=()
  mapfile -t unitfiles < <(
    systemctl list-unit-files --type=service --no-legend \
      | awk '{print $1}' | grep -E "^${base}@\.service$" || true
  )
  for uf in "${unitfiles[@]}"; do
    systemctl disable "$uf" 2>/dev/null || true
  done

  # 清理 wants 残链（主 + 模板）
  rm -f "/etc/systemd/system/multi-user.target.wants/${svc}" 2>/dev/null || true
  rm -f /etc/systemd/system/multi-user.target.wants/"${base}"@*.service 2>/dev/null || true

  systemctl reset-failed "$svc" 2>/dev/null || true
}

remove_unit_files() {
  for f in "$@"; do [ -e "$f" ] && rm -f "$f" || true; done
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true
}

remove_paths(){ for p in "$@"; do [ -e "$p" ] && rm -rf "$p" || true; done; }

remove_user_group() {
  local user="$1" group="${2:-$1}"
  local home
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  if id -u "$user" >/devnull 2>&1; then userdel -r "$user" 2>/dev/null || true; fi
  [ -n "${home:-}" ] && [ -d "$home" ] && rm -rf "$home" || true
  getent group "$group" >/dev/null 2>&1 && groupdel "$group" 2>/dev/null || true
}

pause(){ echo; read -rp "按回车返回主菜单..." _; }

# ===== Hysteria2（含多变体）=====
uninstall_hysteria() {
  echo ">>> 卸载 Hysteria2 ..."
  # 常见基名：hysteria2、hysteria、hysteria-server
  for base in "hysteria2" "hysteria" "hysteria-server"; do
    stop_disable_service "$base"
    remove_unit_files \
      "/etc/systemd/system/${base}.service" \
      "/etc/systemd/system/${base}@.service"
  done
  remove_paths \
    /usr/local/bin/hysteria \
    /etc/hysteria \
    /var/lib/hysteria \
    /var/log/hysteria \
    /etc/logrotate.d/hysteria
  remove_user_group "hysteria"
  remove_user_group "hysteria2" || true
  echo "[OK] Hysteria2 卸载完成。"
}

# ===== Snell =====
uninstall_snell() {
  echo ">>> 卸载 Snell ..."
  for base in "snell" "snell-server"; do
    stop_disable_service "$base"
    remove_unit_files "/etc/systemd/system/${base}.service"
  done
  remove_paths \
    /usr/local/bin/snell \
    /usr/local/bin/snell-server \
    /usr/local/sbin/snell.sh \
    /etc/snell \
    /var/lib/snell \
    /var/log/snell \
    /etc/logrotate.d/snell
  remove_user_group "snell"
  remove_user_group "snell-server" || true
  echo "[OK] Snell 卸载完成。"
}

# ===== TUIC（含 tuic / tuic-server 变体）=====
uninstall_tuic() {
  echo ">>> 卸载 TUIC ..."
  for base in "tuic" "tuic-server"; do
    stop_disable_service "$base"
    remove_unit_files "/etc/systemd/system/${base}.service"
  done
  remove_paths \
    /usr/local/bin/tuic /usr/local/bin/tuic-server \
    /etc/tuic \
    /var/lib/tuic \
    /var/log/tuic \
    /etc/logrotate.d/tuic
  remove_user_group "tuic"
  echo "[OK] TUIC 卸载完成。"
}

# ===== Shadowsocks-Rust（含模板/变体）=====
uninstall_ssrust() {
  echo ">>> 卸载 Shadowsocks-Rust ..."
  for base in "ssrust" "ssserver" "shadowsocks-rust"; do
    stop_disable_service "$base"
    remove_unit_files \
      "/etc/systemd/system/${base}.service" \
      "/etc/systemd/system/${base}@.service"
  done
  remove_paths \
    /usr/local/bin/ssserver \
    /usr/local/sbin/ssrust.sh \
    /usr/local/bin/ssrust \
    /etc/ssrust \
    /var/lib/ssrust \
    /var/log/ssrust \
    /etc/logrotate.d/ssrust
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
    /usr/local/bin/shoes-server \
    /usr/local/bin/shoes.bak.* \
    /etc/shoes \
    /var/lib/shoes \
    /var/log/shoes \
    /etc/logrotate.d/shoes
  remove_user_group "shoes"
  echo "[OK] Shoes 卸载完成。"
}

# ===== ShadowQUIC =====
uninstall_shadowquic() {
  echo ">>> 卸载 ShadowQUIC ..."
  stop_disable_service "shadowquic"
  remove_unit_files /etc/systemd/system/shadowquic.service
  remove_paths \
    /usr/local/bin/shadowquic \
    /etc/shadowquic \
    /var/lib/shadowquic \
    /var/log/shadowquic \
    /etc/logrotate.d/shadowquic
  remove_user_group "shadowquic"
  echo "[OK] ShadowQUIC 卸载完成。"
}

# ===== Xray（补充 share / logrotate / geodata）=====
uninstall_xray() {
  echo ">>> 卸载 Xray ..."
  stop_disable_service "xray"
  remove_unit_files /etc/systemd/system/xray.service
  remove_paths \
    /usr/local/bin/xray \
    /etc/xray \
    /var/lib/xray \
    /var/log/xray \
    /usr/local/share/xray \
    /usr/share/xray \
    /etc/logrotate.d/xray
  remove_user_group "xray"
  echo "[OK] Xray 卸载完成。"
}

# ===== sing-box（补充补全文件）=====
uninstall_singbox() {
  echo ">>> 卸载 sing-box ..."
  stop_disable_service "sing-box"
  remove_unit_files /etc/systemd/system/sing-box.service
  remove_paths \
    /usr/local/bin/sing-box \
    /etc/sing-box \
    /var/lib/sing-box \
    /var/log/sing-box \
    /usr/share/sing-box /usr/local/share/sing-box \
    /etc/logrotate.d/sing-box \
    /usr/share/bash-completion/completions/sing-box \
    /usr/share/zsh/site-functions/_sing-box \
    /usr/share/fish/vendor_completions.d/sing-box.fish
  remove_user_group "sing-box"
  echo "[OK] sing-box 卸载完成。"
}

# ===== v2ray（第 9 个，安全可选）=====
uninstall_v2ray() {
  echo ">>> 卸载 v2ray（如未安装将跳过）..."
  stop_disable_service "v2ray"
  remove_unit_files /etc/systemd/system/v2ray.service
  remove_paths \
    /usr/bin/v2ray /usr/local/bin/v2ray \
    /usr/bin/v2ctl /usr/local/bin/v2ctl \
    /etc/v2ray \
    /var/lib/v2ray \
    /var/log/v2ray \
    /usr/share/v2ray /usr/local/share/v2ray \
    /etc/logrotate.d/v2ray
  remove_user_group "v2ray" || true
  echo "[OK] v2ray 卸载完成（或已不存在）。"
}

# ===== 残留扫描与漂白（可选）=====
bleach_leftovers() {
  echo ">>> 扫描常见残留 ..."
  # 只删这些“看见就删”的顶层目录/文件，避免误伤系统文件
  local globs=(
    "/etc/*/config.json"
    "/etc/*/*.json"
    "/var/log/xray*"
    "/var/log/tuic*"
    "/var/log/hysteria*"
    "/var/log/sing-box*"
    "/var/log/shadowquic*"
    "/var/lib/xray*"
    "/var/lib/tuic*"
    "/var/lib/hysteria*"
    "/var/lib/sing-box*"
    "/usr/local/share/xray*"
    "/usr/share/xray*"
  )
  for g in "${globs[@]}"; do
    for p in $g; do [ -e "$p" ] && { echo "  - 删除 $p"; rm -rf "$p"; }; done
  done
  echo "[OK] 漂白完成。"
}

# ===== 卸载所有 =====
uninstall_all() {
  echo ">>> 将卸载所有：Hysteria2 / Snell / TUIC / SSRust / Shoes / ShadowQUIC / Xray / sing-box / v2ray"
  uninstall_hysteria
  uninstall_snell
  uninstall_tuic
  uninstall_ssrust
  uninstall_shoes
  uninstall_shadowquic
  uninstall_xray
  uninstall_singbox
  uninstall_v2ray
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
6) 卸载 ShadowQUIC
7) 卸载 Xray
8) 卸载 sing-box
9) 卸载 v2ray
a) 卸载以上所有
b) 残留扫描与漂白（可选）
0) 退出
=========================================
MENU
    read -rp "请选择 [0-9ab]: " choice
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
      9) uninstall_v2ray;       pause ;;
      a|A) uninstall_all;       pause ;;
      b|B) bleach_leftovers;    pause ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "无效选择"; pause ;;
    esac
  done
}

need_root
exists_cmd systemctl || { echo "需要 systemd 环境"; exit 1; }
main_menu
