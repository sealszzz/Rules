#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

need_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "run as root"; exit 1; }
}

is_container() {
  systemd-detect-virt --container >/dev/null 2>&1
}

wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 1
  done
}

install_pkgs() {
  wait_for_apt
  apt-get update
  wait_for_apt
  apt-get install -y --no-install-recommends chrony ca-certificates
}

configure_timedated_prefer_chrony() {
  command -v systemctl >/dev/null 2>&1 || return 0
  install -d -m 0755 /etc/systemd/system/systemd-timedated.service.d
  cat >/etc/systemd/system/systemd-timedated.service.d/override.conf <<'EOF'
[Service]
Environment=SYSTEMD_TIMEDATED_NTP_SERVICES=chrony.service:systemd-timesyncd.service
EOF
  systemctl daemon-reload
  systemctl try-restart systemd-timedated.service 2>/dev/null || true
}

wait_for_chrony() {
  local i
  for i in $(seq 1 15); do
    if chronyc tracking 2>/dev/null | grep -q '^Leap status[[:space:]]*:[[:space:]]*Normal$'; then
      echo "[ntp] synchronized"
      return 0
    fi
    sleep 2
  done

  echo "[ntp] chrony failed to synchronize in time"
  chronyc tracking || true
  chronyc sources -v || true
  timedatectl status || true
  exit 1
}

sync_time_utc() {
  command -v timedatectl >/dev/null 2>&1 || return 0
  command -v systemctl >/dev/null 2>&1 || return 0

  echo "[time] timezone -> Etc/UTC"
  timedatectl set-timezone Etc/UTC 2>/dev/null || true

  if ! is_container; then
    if [ "$(timedatectl show -p LocalRTC --value 2>/dev/null || echo no)" = "yes" ]; then
      timedatectl set-local-rtc 0 2>/dev/null || true
    fi
  fi

  install_pkgs
  configure_timedated_prefer_chrony

  systemctl disable --now systemd-timesyncd.service ntp.service ntpd.service openntpd.service 2>/dev/null || true
  systemctl enable --now chrony.service
  systemctl restart chrony.service

  timedatectl set-ntp true 2>/dev/null || true
  wait_for_chrony
}

apply_sysctl_tuning() {
  install -d -m 0755 /etc/sysctl.d
  modprobe nf_conntrack 2>/dev/null || true

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

maybe_reboot() {
  if is_container; then
    return 0
  fi
  sleep 5
  reboot
}

main() {
  need_root
  sync_time_utc
  apply_sysctl_tuning
  maybe_reboot
}

main "$@"
