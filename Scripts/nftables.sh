bash -c 'set -euo pipefail

# --- 0) 发现当前 SSH 端口（回落 2222） ---
get_ssh_port() {
  if command -v sshd >/dev/null 2>&1; then
    local p
    p="$(sshd -T 2>/dev/null | awk "/^port /{print \$2; exit}")" || true
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] && { echo "$p"; return; }
  fi
  local g
  g="$(awk "/^[Pp][Oo][Rr][Tt][[:space:]]+[0-9]+/{print \$2; exit}" /etc/ssh/sshd_config 2>/dev/null)" || true
  [[ "$g" =~ ^[0-9]+$ ]] && [ "$g" -ge 1 ] && [ "$g" -le 65535 ] && { echo "$g"; return; }
  echo 2222
}
SSH_PORT="$(get_ssh_port)"
echo "[*] SSH port detected: ${SSH_PORT}"

# --- 1) 安装 nftables ---
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends nftables

# --- 2) 写入并应用规则 ---
cat >/etc/nftables.conf <<EOF
flush ruleset

table inet filter {
  # 黑名单（长封，7d；再次 add 会刷新超时）
  set blacklist4 { type ipv4_addr; timeout 7d; }
  set blacklist6 { type ipv6_addr; timeout 7d; }

  # 允许端口（按你的环境）
  set tcp_allow { type inet_service; elements = { ${SSH_PORT}, 80, 443, 8443, 8448 }; }
  set udp_allow { type inet_service; elements = { 443, 8443, 8448 }; }

  chain input {
    type filter hook input priority 0; policy drop;

    # 1) 早期黑名单丢弃
    ip  saddr @blacklist4 drop
    ip6 saddr @blacklist6 drop

    # 2) 基线
    ct state invalid drop
    ct state established,related accept
    iif lo accept

    # 可达性（建议保留）
    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept

    # 2.5) DHCPv4/v6：仅在“确定不用 DHCP(6)”时再启用以下两行
    # udp dport { 67, 68 } drop          # DHCPv4
    # udp dport { 546, 547 } drop        # DHCPv6

    # 3) 未开放端口策略：
    #   TCP：仅对“初始 SYN 且未在允许列表”的连接加黑
    tcp flags & (syn | ack) == syn tcp dport != @tcp_allow ct state new ip  saddr != 0.0.0.0 add @blacklist4 { ip saddr }  counter drop
    tcp flags & (syn | ack) == syn tcp dport != @tcp_allow ct state new ip6 saddr != ::      add @blacklist6 { ip6 saddr } counter drop

    #   UDP：未开放端口仅丢弃，不加黑
    udp dport != @udp_allow ct state new counter drop

    # 允许端口的新建必须是 SYN（仅作用 TCP，不影响 QUIC/UDP）
    tcp dport @tcp_allow ct state new tcp flags & (fin|syn|rst|ack) != syn counter drop

    # 5) 最终放行允许端口
    tcp dport @tcp_allow accept
    udp dport @udp_allow accept
  }

  chain forward { type filter hook forward priority 0; policy drop; }
  chain output  { type filter hook output  priority 0; policy accept; }
}
EOF

# 语法检查 & 应用 & 持久化
nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable --now nftables

echo
echo "=== nftables ruleset (head) ==="
nft list ruleset | sed -n "1,200p" || true

echo
echo "[*] 常用操作："
echo "  手动拉黑(IPv4, 7d)：nft add element inet filter blacklist4 { 198.51.100.10 }"
echo "  查看集合：nft list set inet filter blacklist4 ; nft list set inet filter blacklist6"
'
