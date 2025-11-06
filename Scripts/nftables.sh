#!/usr/bin/env bash
set -euo pipefail

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

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends nftables

cat >/etc/nftables.conf <<EOF
flush ruleset

table inet filter {
  set blacklist4 { type ipv4_addr; flags dynamic; timeout 7d; size 65535; gc-interval 5m; }
  set blacklist6 { type ipv6_addr; flags dynamic; timeout 7d; size 65535; gc-interval 5m; }

  set tcp_allow { type inet_service; elements = { ${SSH_PORT}, 80, 443, 4443, 8443, 8448 }; }
  set udp_allow { type inet_service; elements = { 443, 4443, 8443, 8448 }; }

  chain input {
    type filter hook input priority 0; policy drop;

    ip  saddr @blacklist4 drop
    ip6 saddr @blacklist6 drop

    ct state invalid drop
    ct state established,related accept
    iif lo accept

    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept

    tcp flags & syn == syn tcp dport != @tcp_allow ct state new ip  saddr != 0.0.0.0 add @blacklist4 { ip saddr }  counter drop
    tcp flags & syn == syn tcp dport != @tcp_allow ct state new ip6 saddr != ::      add @blacklist6 { ip6 saddr } counter drop

    udp dport != @udp_allow ct state new counter drop

    tcp dport @tcp_allow ct state new tcp flags & (fin|syn|rst|ack) != syn counter drop

    tcp dport @tcp_allow accept
    udp dport @udp_allow accept
  }

  chain forward { type filter hook forward priority 0; policy drop; }
  chain output  { type filter hook output  priority 0; policy accept; }
}
EOF

nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable --now nftables

echo
echo "=== nftables ruleset (head) ==="
nft list ruleset | sed -n "1,200p" || true

echo
echo "[*] 常用操作："
echo "  手动拉黑(IPv4)：nft add element inet filter blacklist4 { 198.51.100.10 }"
echo "  解除拉黑(IPv4)：nft delete element inet filter blacklist4 { 198.51.100.10 }"
echo "  查看集合：nft list set inet filter blacklist4 ; nft list set inet filter blacklist6"
