#!/usr/bin/env bash
# init-all.sh — Debian 13: TZ/NTP(wait,no set-ntp) → nftables → SSH no-pass → BBR → reboot
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "run as root"; exit 1; }; }
wait_for_apt(){ while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do sleep 1; done; }
get_ssh_port(){
  if command -v sshd >/dev/null 2>&1; then
    local p; p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')" || true
    [[ "$p" =~ ^[0-9]+$ ]] && { echo "$p"; return; }
  fi
  local g; g="$(awk '/^[Pp][Oo][Rr][Tt][[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)" || true
  [[ "$g" =~ ^[0-9]+$ ]] && echo "$g" || echo 8888
}

need_root

# 1) TZ/RTC/NTP（不调用 set-ntp，避免 “NTP not supported”）
timedatectl set-timezone Etc/UTC || true
timedatectl set-local-rtc 0 || true
if ! systemctl list-unit-files | grep -q '^systemd-timesyncd\.service'; then
  wait_for_apt; apt-get update
  wait_for_apt; apt-get install -y --no-install-recommends systemd-timesyncd ca-certificates
fi
systemctl unmask systemd-timesyncd.service 2>/dev/null || true
systemctl enable --now systemd-timesyncd || true
systemctl restart systemd-timesyncd || true
for _ in $(seq 1 90); do
  v="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  [ "$v" = "yes" ] && break
  sleep 2
done

# 2) nftables（安装→规则→开机自启）
wait_for_apt; apt-get install -y --no-install-recommends nftables
SSH_PORT="$(get_ssh_port)"

# 注意：这里用无引号 heredoc，让 ${SSH_PORT} 正常展开
cat >/etc/nftables.conf <<EOF
flush ruleset

table inet filter {
  set blacklist4 {
    type ipv4_addr
    flags dynamic, timeout
    timeout 7d
    size 65535
    gc-interval 5m
  }

  set blacklist6 {
    type ipv6_addr
    flags dynamic, timeout
    timeout 7d
    size 65535
    gc-interval 5m
  }
  
  set tcp_allow {
    type inet_service
    flags interval
    elements = { 80, 443, 8443, 8448, ${SSH_PORT} }
  }

  set udp_allow {
    type inet_service
    flags interval
    elements = { 443, 8443, 8448 }
  }

  chain input {
    type filter hook input priority filter; policy drop;

    ip  saddr @blacklist4 counter drop
    ip6 saddr @blacklist6 counter drop

    ct state invalid counter drop
    ct state { established, related } accept

    iif lo accept

    ip protocol icmp icmp type {
      echo-request, destination-unreachable, time-exceeded
    } limit rate 10/second accept

    ip6 nexthdr ipv6-icmp icmpv6 type {
      nd-neighbor-solicit, nd-neighbor-advert,
      nd-router-solicit, nd-router-advert
    } accept

    ip6 nexthdr ipv6-icmp icmpv6 type {
      echo-request, destination-unreachable, time-exceeded, packet-too-big, parameter-problem
    } limit rate 10/second accept

    meta nfproto ipv4 tcp flags syn tcp dport != @tcp_allow ct state new \
      ip saddr != 0.0.0.0 add @blacklist4 { ip saddr timeout 7d } counter drop
    meta nfproto ipv6 tcp flags syn tcp dport != @tcp_allow ct state new \
      ip6 saddr != :: add @blacklist6 { ip6 saddr timeout 7d } counter drop

    udp dport != @udp_allow ct state new counter drop

    tcp dport @tcp_allow ct state new tcp flags & (fin|syn|rst|ack) != syn counter drop

    tcp flags & (fin|syn|rst|psh|ack|urg) == fin|syn counter drop comment "FIN+SYN"
    tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0   counter drop comment "NULL scan"
    tcp flags & (fin|psh|urg) == fin|psh|urg       counter drop comment "XMAS scan"

    tcp dport @tcp_allow accept
    udp dport @udp_allow accept
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
EOF

nft -c -f /etc/nftables.conf
nft -f  /etc/nftables.conf
systemctl enable --now nftables

# 3) SSH 免密（校验失败自动回滚）
install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-no-password.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF
if sshd -t 2>/dev/null; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
else
  rm -f /etc/ssh/sshd_config.d/99-no-password.conf
fi

# 4) BBR
cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl --system >/dev/null || true

# 5) 重启
sleep 5
reboot
