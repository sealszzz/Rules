#!/usr/bin/env bash
set -euo pipefail

echo "== NetStack 卸载与回滚 =="

need_root() { [[ $EUID -eq 0 ]] || { echo "请用 root 运行：sudo bash $0"; exit 1; }; }

# 从已安装配置解析端口
get_ss_port() {
  if [[ -f /etc/ss-rust/config.json ]]; then
    awk -F: '/"server_port"/ {gsub(/[ ,]/,"",$2); print $2}' /etc/ss-rust/config.json 2>/dev/null || true
  fi
}
get_snell_port() {
  if [[ -f /etc/snell/snell-server.conf ]]; then
    awk -F= '/^listen/{gsub(/[ \t]/,""); split($2,a,":"); print a[length(a)]}' /etc/snell/snell-server.conf 2>/dev/null || true
  fi
}
get_shadowtls_port() {
  # 从 systemd 单元里找 -p/--port 参数
  if [[ -f /etc/systemd/system/shadow-tls.service ]]; then
    grep -E 'ExecStart=' /etc/systemd/system/shadow-tls.service | \
    sed -E 's/.*(^|[[:space:]])-p[[:space:]]+([0-9]+).*/\2/' | tail -n1
  fi
}

# 撤销 UFW 规则（若启用）
revoke_ufw() {
  local p
  if command -v ufw >/dev/null 2>&1; then
    echo "[防火墙] 尝试撤销 UFW 规则..."
    for p in "$@"; do
      [[ -n "${p:-}" ]] || continue
      ufw delete allow ${p}/tcp 2>/dev/null || true
      ufw delete allow ${p}/udp 2>/dev/null || true
    done
    ufw status || true
  fi
}

# 撤销 nftables 规则：按端口查 handle 并删除
revoke_nft() {
  local p
  if command -v nft >/dev/null 2>&1; then
    echo "[防火墙] 尝试撤销 nftables 临时规则..."
    nft list chain inet filter input -a >/tmp/nft_input_rules.txt 2>/dev/null || true
    for p in "$@"; do
      [[ -n "${p:-}" ]] || continue
      # 删除匹配 tcp/udp dport p 的规则
      for proto in tcp udp; do
        # 按 handle 删除
        grep -E "[[:space:]]${proto}[[:space:]]dport[[:space:]]${p}[[:space:]]" /tmp/nft_input_rules.txt | \
        awk -F'# handle ' '{print $2}' | while read -r h; do
          [[ -n "$h" ]] && nft delete rule inet filter input handle "$h" 2>/dev/null || true
        done
      done
    done
    rm -f /tmp/nft_input_rules.txt
    nft list ruleset | sed -n '1,120p' || true
    echo "提示：如果你曾把规则写进 /etc/nftables.conf，请手动移除并运行：systemctl reload nftables"
  fi
}

stop_disable_service() {
  local svc="$1"
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
}

remove_unit() {
  local unit="$1"
  [[ -f "/etc/systemd/system/${unit}" ]] && rm -f "/etc/systemd/system/${unit}"
}

confirm() {
  local msg="$1" ans
  read -rp "$msg [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

main() {
  need_root

  echo "收集端口信息..."
  SS_PORT="$(get_ss_port || true)"
  SNELL_PORT="$(get_snell_port || true)"
  STLS_PORT="$(get_shadowtls_port || true)"
  echo "  SS2022 端口:   ${SS_PORT:-未发现}"
  echo "  Snell   端口:   ${SNELL_PORT:-未发现}"
  echo "  ShadowTLS 端口: ${STLS_PORT:-未发现}"

  # 停止并禁用服务
  echo "停止服务..."
  stop_disable_service ss-rust.service
  stop_disable_service snell.service
  stop_disable_service shadow-tls.service

  # 撤销防火墙规则
  revoke_ufw "${SS_PORT:-}" "${SNELL_PORT:-}" "${STLS_PORT:-}"
  revoke_nft "${SS_PORT:-}" "${SNELL_PORT:-}" "${STLS_PORT:-}"

  # 移除二进制（可选保留）
  if confirm "删除二进制文件（/usr/local/bin/ssserver /usr/local/bin/snell-server /usr/local/bin/shadow-tls）吗？"; then
    rm -f /usr/local/bin/ssserver 2>/dev/null || true
    rm -f /usr/local/bin/snell-server 2>/dev/null || true
    rm -f /usr/local/bin/shadow-tls 2>/dev/null || true
  else
    echo "已选择保留二进制。"
  fi

  # 移除配置（可选保留）
  if confirm "删除配置目录（/etc/ss-rust /etc/snell）吗？（ShadowTLS 仅 systemd 参数，无单独目录）"; then
    rm -rf /etc/ss-rust 2>/dev/null || true
    rm -rf /etc/snell 2>/dev/null || true
  else
    echo "已选择保留配置。"
  fi

  # 移除 systemd unit
  echo "清理 systemd unit..."
  remove_unit ss-rust.service
  remove_unit snell.service
  remove_unit shadow-tls.service
  systemctl daemon-reload

  echo "完成。你可以用以下命令确认："
  echo "  ss -lntup | grep -E ':(${SS_PORT}|${SNELL_PORT}|${STLS_PORT})\\b' || true"
  echo "  systemctl list-units | grep -E 'ss-rust|snell|shadow-tls' || true"
  echo
  echo "如需彻底还原 UFW/nftables 状态，请按你的环境策略手动审计规则。"
}

main "$@"
