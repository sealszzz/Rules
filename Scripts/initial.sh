#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "run as root"; exit 1; }; }
waitapt(){ while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do sleep 1; done; }

get_ssh_port(){
  if command -v sshd >/dev/null 2>&1; then
    p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')" || true
    [[ "$p" =~ ^[0-9]+$ ]] && { echo "$p"; return; }
  fi
  g="$(awk '/^[Pp][Oo][Rr][Tt][[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)" || true
  [[ "$g" =~ ^[0-9]+$ ]] && { echo "$g"; return; }
  echo 2222
}

need_root

# 1) TZ / RTC / NTP（等待同步）
timedatectl set-timezone Etc/UTC
timedatectl set-local-rtc 0
timedatectl set-ntp true || true
waitapt; apt-get update -y
waitapt; apt-get install -y --no-install-recommends systemd-timesyncd ca-certificates
systemctl enable --now systemd-timesyncd || true

for _ in $(seq 1 90); do
  [ "$(timedatectl 2>/dev/null | awk -F': ' '/System clock synchronized/{print $2}')" = "yes" ] && break
  sleep 2
done

# 2) nftables（必须安装 + 必须加载模块）
waitapt; apt-get install -y --no-install-recommends nftables iproute2

# **这是昨天你系统能正常的关键：强制提前加载 nf_tables 模块**
for m in nfnetlink nf_tables nf_conntrack nf_defrag_ipv4 nf_defrag_ipv6; do
  modprobe -q "$m" 2>/dev/null || true
done

SSH_PORT="$(get_ssh_port)"

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

    tcp flags & syn == syn tcp dport != @tcp_allow ct state new ip saddr add @blacklist4 { ip saddr } drop
    udp dport != @udp_allow ct state new drop

    tcp dport @tcp_allow accept
    udp dport @udp_allow accept
  }

  chain forward { type filter hook forward priority 0; policy drop; }
  chain output  { type filter hook output priority 0; policy accept; }
}
EOF

nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable --now nftables

# 3) SSH 禁密
install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-no-password.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF
sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; } || rm -f /etc/ssh/sshd_config.d/99-no-password.conf

# 4) BBR
cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl --system >/dev/null

# 5) XanMod 必装
install -d -m 0755 /etc/apt/keyrings
waitapt; apt-get install -y --no-install-recommends wget gpg
wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org trixie main' >/etc/apt/sources.list.d/xanmod-release.list
waitapt; apt-get update -y
waitapt; apt-get install -y linux-xanmod-lts-x64v3

sleep 5
reboot
