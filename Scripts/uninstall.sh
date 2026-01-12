#!/usr/bin/env bash
# 完整卸载脚本（不清理依赖，不做备份）
# 覆盖：caddy / xray / sing-box / tuic / juicity / shoes / shadowquic / snell / hysteria / anytls
# 说明：不再兼容任何 *-server / anytls-go / anytls-rust 等旧命名；只按“当前安装脚本”的命名卸载
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
  stop_disable_service "sing-box"
  remove_unit_artifacts "sing-box"
  remove_paths \
    /usr/local/bin/sing-box \
    /etc/sing-box /var/lib/sing-box /var/log/sing-box \
    /etc/logrotate.d/sing-box
  remove_user_group "sing-box" "sing-box" || true
  echo "[OK] sing-box 卸载完成。"
}

uninstall_tuic() {
  echo ">>> 卸载 TUIC ..."
  stop_disable_service "tuic"
  remove_unit_artifacts "tuic"
  remove_paths \
    /usr/local/bin/tuic \
    /etc/tuic /var/lib/tuic /var/log/tuic \
    /etc/logrotate.d/tuic
  remove_user_group "tuic" || true
  echo "[OK] TUIC 卸载完成。"
}

uninstall_juicity() {
  echo ">>> 卸载 Juicity ..."
  stop_disable_service "juicity"
  remove_unit_artifacts "juicity"
  remove_paths \
    /usr/local/bin/juicity \
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
    /usr/local/bin/shoes \
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
  stop_disable_service "snell"
  remove_unit_artifacts "snell"
  remove_paths \
    /usr/local/bin/snell \
    /etc/snell /var/lib/snell /var/log/snell \
    /etc/logrotate.d/snell
  remove_user_group "snell" || true
  echo "[OK] Snell 卸载完成。"
}

uninstall_hysteria() {
  echo ">>> 卸载 Hysteria2 ..."
  stop_disable_service "hysteria"
  remove_unit_artifacts "hysteria"
  remove_paths \
    /usr/local/bin/hysteria \
    /etc/hysteria /var/lib/hysteria /var/log/hysteria \
    /etc/logrotate.d/hysteria
  remove_user_group "hysteria" || true
  echo "[OK] Hysteria2 卸载完成。"
}

uninstall_anytls() {
  echo ">>> 卸载 AnyTLS ..."
  stop_disable_service "anytls"
  remove_unit_artifacts "anytls"
  remove_paths \
    /usr/local/bin/anytls \
    /etc/anytls /var/lib/anytls /var/log/anytls \
    /etc/logrotate.d/anytls
  remove_user_group "anytls" || true
  echo "[OK] AnyTLS 卸载完成。"
}

uninstall_all() {
  echo ">>> 将卸载所有：Caddy / Xray / sing-box / TUIC / Juicity / Shoes / ShadowQUIC / Snell / Hysteria2 / AnyTLS"
  uninstall_caddy
  uninstall_xray
  uninstall_singbox
  uninstall_tuic
  uninstall_juicity
  uninstall_shoes
  uninstall_shadowquic
  uninstall_snell
  uninstall_hysteria
  uninstall_anytls
  echo "[OK] 所有组件已卸载。"
}

# ---------------- 选择式菜单：0 执行卸载；11 卸载所有 ----------------
declare -A SEL=(
  [caddy]=0
  [xray]=0
  [singbox]=0
  [tuic]=0
  [juicity]=0
  [shoes]=0
  [shadowquic]=0
  [snell]=0
  [hysteria]=0
  [anytls]=0
)

toggle() {
  local key="$1"
  if [ "${SEL[$key]:-0}" -eq 1 ]; then SEL[$key]=0; else SEL[$key]=1; fi
}

run_selected() {
  echo ">>> 开始卸载已勾选组件 ..."
  local any=0
  for k in caddy xray singbox tuic juicity shoes shadowquic snell hysteria anytls; do
    if [ "${SEL[$k]:-0}" -eq 1 ]; then
      any=1
      case "$k" in
        caddy)      uninstall_caddy ;;
        xray)       uninstall_xray ;;
        singbox)    uninstall_singbox ;;
        tuic)       uninstall_tuic ;;
        juicity)    uninstall_juicity ;;
        shoes)      uninstall_shoes ;;
        shadowquic) uninstall_shadowquic ;;
        snell)      uninstall_snell ;;
        hysteria)   uninstall_hysteria ;;
        anytls)     uninstall_anytls ;;
      esac
      echo
    fi
  done
  if [ "$any" -eq 0 ]; then
    echo "未选择任何组件（先输入编号勾选/取消勾选）。"
  else
    echo "[OK] 已完成勾选项卸载。"
  fi
}

main_menu() {
  while true; do
    clear
    cat <<MENU
==================== 卸载菜单 ====================
输入编号可【勾选/取消勾选】，然后：
  0  执行卸载（卸载当前已勾选）
  11 卸载所有
  q  退出

 1) [$([ "${SEL[caddy]}"      -eq 1 ] && echo x || echo ' ')] 卸载 Caddy (含 caddy-l4)
 2) [$([ "${SEL[xray]}"       -eq 1 ] && echo x || echo ' ')] 卸载 Xray
 3) [$([ "${SEL[singbox]}"    -eq 1 ] && echo x || echo ' ')] 卸载 sing-box
 4) [$([ "${SEL[tuic]}"       -eq 1 ] && echo x || echo ' ')] 卸载 TUIC
 5) [$([ "${SEL[juicity]}"    -eq 1 ] && echo x || echo ' ')] 卸载 Juicity
 6) [$([ "${SEL[shoes]}"      -eq 1 ] && echo x || echo ' ')] 卸载 Shoes
 7) [$([ "${SEL[shadowquic]}" -eq 1 ] && echo x || echo ' ')] 卸载 ShadowQUIC
 8) [$([ "${SEL[snell]}"      -eq 1 ] && echo x || echo ' ')] 卸载 Snell
 9) [$([ "${SEL[hysteria]}"   -eq 1 ] && echo x || echo ' ')] 卸载 Hysteria2
10) [$([ "${SEL[anytls]}"     -eq 1 ] && echo x || echo ' ')] 卸载 AnyTLS
==================================================
MENU

    read -rp "请输入（可多选，用空格分隔）: " line
    echo
    line="${line:-}"
    [ -z "$line" ] && continue

    # shellcheck disable=SC2206
    tokens=($line)

    for t in "${tokens[@]}"; do
      case "$t" in
        1)  toggle caddy ;;
        2)  toggle xray ;;
        3)  toggle singbox ;;
        4)  toggle tuic ;;
        5)  toggle juicity ;;
        6)  toggle shoes ;;
        7)  toggle shadowquic ;;
        8)  toggle snell ;;
        9)  toggle hysteria ;;
        10) toggle anytls ;;
        11) uninstall_all; pause ;;
        0)  run_selected; pause ;;
        q|Q|quit|exit) echo "Bye."; exit 0 ;;
        *)  echo "无效输入：$t" ;;
      esac
    done
  done
}

need_root
exists_cmd systemctl || { echo "需要 systemd 环境"; exit 1; }
main_menu
