#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

need_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "run as root"; exit 1; }
}

wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 1
  done
}

sync_time_utc() {
  command -v timedatectl >/dev/null 2>&1 || return 0
  command -v systemctl >/dev/null 2>&1 || return 0

  echo "[time] timezone -> Etc/UTC"
  timedatectl set-timezone Etc/UTC || true
  timedatectl set-local-rtc 0 || true

  if ! systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    wait_for_apt
    apt-get update
    wait_for_apt
    apt-get install -y --no-install-recommends systemd-timesyncd
  fi

  systemctl unmask systemd-timesyncd.service || true
  timedatectl set-ntp true || true

  for i in $(seq 1 15); do
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" = "yes" ]; then
      echo "[ntp] synchronized"
      return 0
    fi
    sleep 1
  done

  echo "[ntp] warning: not yet synchronized"
}

apply_sysctl_tuning() {
  install -d -m 0755 /etc/sysctl.d

  cat >/etc/sysctl.d/99-sysctl.conf <<'EOF'
# ===== TCP (BBR) =====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 4096
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384

# ===== TCP: Path MTU blackhole protection =====
net.ipv4.tcp_mtu_probing = 1

# ===== Conntrack / QUIC / UDP =====
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60

# ===== Socket Buffers =====
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
EOF

  sysctl --system >/dev/null || true
}

main() {
  need_root
  sync_time_utc
  apply_sysctl_tuning
  sleep 5
  reboot
}

main "$@"
