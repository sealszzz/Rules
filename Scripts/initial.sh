#!/usr/bin/env bash
# init-all.sh — Debian 13: TZ/NTP(wait) → nftables → SSH no-pass → BBR → reboot
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "run as root"; exit 1; }; }
wait_for_apt(){
  # 等待后台 cloud-init/apt/dpkg 锁
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

# 更稳的 NTP 等待（最长 300s；只要 NTPSynchronized=yes 即通过）
wait_ntp_sync() {
  local timeout=300 elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" = "yes" ]; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed+2))
  done
  echo "WARN: NTP not synchronized after ${timeout}s; continuing." >&2
  return 1
}

need_root

# 1) TZ/RTC/NTP + wait until synchronized (max ~300s)
timedatectl set-timezone Etc/UTC
timedatectl set-local-rtc 0

# —— 统一使用 systemd-timesyncd，避免与 chrony/ntp 并存 —— #
# 若存在其它 NTP 实现，先停用以免 timedatectl 状态混乱
systemctl list-unit-files | grep -q '^chrony\.service' && { systemctl disable --now chrony || true; }
systemctl list-unit-files | grep -q '^ntp\.service'    && { systemctl disable --now ntp    || true; }

# 安装并启用 timesyncd（先 unmask 避免某些镜像默认屏蔽）
systemctl unmask systemd-timesyncd.service 2>/dev/null || true
if ! systemctl list-unit-files | grep -q '^systemd-timesyncd\.service'; then
  wait_for_apt; apt-get update
  wait_for_apt; apt-get install -y --no-install-recommends systemd-timesyncd ca-certificates
fi

# 可选：写入可信时间源（留空则使用发行版默认）
install -d -m 0755 /etc/systemd
cat >/etc/systemd/timesyncd.conf <<'EOF'
[Time]
NTP=time.cloudflare.com time.google.com ntp.ubuntu.com
FallbackNTP=pool.ntp.org
EOF

systemctl enable --now systemd-timesyncd || true
# 只有当 timesyncd 存在时才设置 NTP=on（防止 "NTP not supported"）
timedatectl set-ntp true || true
# 配置变更后重启服务，触发尽快初次对时
systemctl restart systemd-timesyncd || true

# 等待首次同步（不强制失败）
wait_ntp_sync || true

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

    meta nfproto ipv4 tcp flags & syn == syn tcp dport != @tcp_allow ct state new \
        add @blacklist4 { ip saddr } counter drop
    meta nfproto ipv6 tcp flags & syn == syn tcp dport != @tcp_allow ct state new \
        add @blacklist6 { ip6 saddr } counter drop

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
