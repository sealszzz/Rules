#!/usr/bin/env bash
# init-all.sh — Debian 13: TZ/NTP(wait) → nftables → SSH no-pass → BBR → reboot
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "run as root"; exit 1; }; }
wait_for_apt(){
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 1
  done
}
get_ssh_port(){
  if command -v sshd >/dev/null 2>&1; then
    local p; p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')" || true
    [[ "$p" =~ ^[0-9]+$ ]] && echo "$p" && return
  fi
  local g; g="$(awk '/^[Pp][Oo][Rr][Tt][[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)" || true
  [[ "$g" =~ ^[0-9]+$ ]] && echo "$g" || echo 2222
}

need_root

# 1) TZ/RTC + 安装/启用 NTP 提供者，再等待同步（最多 ~180s）
timedatectl set-timezone Etc/UTC
timedatectl set-local-rtc 0

# 检测已有 NTP 提供者：优先沿用现有，缺失则安装 timesyncd
has_chrony=false
has_ntpd=false
has_timesyncd=false

systemctl list-unit-files | grep -q '^chrony\.service' && has_chrony=true
systemctl list-unit-files | grep -q '^ntp\.service' && has_ntpd=true
systemctl list-unit-files | grep -q '^systemd-timesyncd\.service' && has_timesyncd=true

if ! $has_chrony && ! $has_ntpd && ! $has_timesyncd; then
  wait_for_apt; apt-get update
  wait_for_apt; apt-get install -y --no-install-recommends systemd-timesyncd ca-certificates
  has_timesyncd=true
fi

# 启用并启动合适的 NTP 服务；仅当 timesyncd 存在时才使用 timedatectl set-ntp
if $has_chrony; then
  systemctl enable --now chrony || true
elif $has_ntpd; then
  systemctl enable --now ntp || true
elif $has_timesyncd; then
  systemctl enable --now systemd-timesyncd || true
  timedatectl set-ntp true || true
fi

# 等待 NTP 同步：优先用 timedatectl 的机器可读标志；不可用就有限等待
for _ in $(seq 1 90); do
  val="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [ "$val" = "yes" ]; then
    break
  fi
  sleep 2
done

# 2) nftables（安装→规则→开机自启）
wait_for_apt; apt-get install -y --no-install-recommends nftables
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

    ct state invalid drop
    ct state established,related accept
    iif lo accept

    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept

    # 端口扫描与黑名单：新建连接、SYN 到非白名单端口 → 动态拉黑并丢弃
    meta nfproto ipv4 tcp flags & syn == syn tcp dport != @tcp_allow ct state new \
        add @blacklist4 { ip saddr } counter drop
    meta nfproto ipv6 tcp flags & syn == syn tcp dport != @tcp_allow ct state new \
        add @blacklist6 { ip6 saddr } counter drop

    # UDP 非允许端口直接丢弃
    udp dport != @udp_allow ct state new counter drop

    # 允许列出的 TCP/UDP
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

# 3) SSH 加固：禁用口令/交互式，保留公钥；root 仅允许密钥
install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-no-password.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF
if sshd -t; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
else
  rm -f /etc/ssh/sshd_config.d/99-no-password.conf
fi

# 4) BBR（按你的偏好 fq+bbr）
cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl --system >/dev/null

# 5) 温和重启
sleep 5
reboot
