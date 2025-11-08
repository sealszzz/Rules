#!/usr/bin/env bash
# initial.sh — Debian 13 初始化（TZ/NTP/nftables）
# 环境变量可覆盖：
#   TIMEZONE=Etc/UTC
#   SKIP_NFTABLES=0
#   REBOOT=0

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

: "${TIMEZONE:=Etc/UTC}"
: "${SKIP_NFTABLES:=0}"
: "${REBOOT:=0}"

log(){ printf '\033[1;32m>>> %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m!!! %s\033[0m\n' "$*"; }
err(){ printf '\033[1;31mxxx %s\033[0m\n' "$*"; }

apt_wait_lock() {
  # 等待 dpkg/apt 锁，防止并发
  for i in {1..30}; do
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
       fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
      sleep 1
    else
      return 0
    fi
  done
  return 1
}

apt_safe() {
  apt_wait_lock || { err "apt/dpkg 锁长期被占用"; exit 1; }
  apt-get -yq "$@"
}

is_systemd() { pidof systemd >/dev/null 2>&1; }
virt_type() { systemd-detect-virt 2>/dev/null || echo "none"; }

# 0) 基本信息
log "Kernel: $(uname -r)"
log "Virt  : $(virt_type)"

# 1) APT 基础
log "Refreshing apt and base packages..."
apt_safe update
apt_safe install ca-certificates apt-transport-https >/dev/null

# 2) 设置时区（timedatectl 可用优先）
log "Setting timezone -> ${TIMEZONE}"
if command -v timedatectl >/dev/null 2>&1 && is_systemd; then
  timedatectl set-timezone "${TIMEZONE}" || warn "timedatectl set-timezone 失败，改用软链"
fi
if [ ! -e /etc/localtime ] || ! readlink -f /etc/localtime | grep -q "/usr/share/zoneinfo/${TIMEZONE}$"; then
  ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  echo "${TIMEZONE}" >/etc/timezone
fi

# 3) 安装并启用 NTP（先装 timesyncd，再 set-ntp）
NTP_OK=0
if is_systemd; then
  if command -v timedatectl >/dev/null 2>&1; then
    # 在容器/不支持修改宿主时间的环境跳过
    case "$(virt_type)" in
      lxc|openvz) warn "容器环境（$(virt_type)），跳过启用 NTP（宿主机控时）";;
      *)
        log "Installing systemd-timesyncd..."
        apt_safe install systemd-timesyncd >/dev/null || true
        systemctl enable systemd-timesyncd >/dev/null 2>&1 || true
        systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
        # 只有在 timesyncd 就绪后再 set-ntp
        if timedatectl set-ntp true 2>/dev/null; then
          NTP_OK=1
        else
          warn "timedatectl set-ntp 未成功，稍后检查状态"
        fi
        ;;
    esac
  else
    warn "timedatectl 不存在，跳过 NTP 开启"
  fi
else
  warn "非 systemd 环境，跳过 NTP 开启"
fi

# 可选：打印 NTP 状态（不使脚本失败）
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl show -p NTPSynchronized -p NTP -p TimeUSec 2>/dev/null || true
fi

# 4) 安装并启用 nftables
if [ "${SKIP_NFTABLES}" != "1" ]; then
  log "Installing & enabling nftables..."
  apt_safe install -y nftables iproute2 >/dev/null || true
  systemctl enable nftables >/dev/null 2>&1 || true
  systemctl start nftables  >/dev/null 2>&1 || true
fi

# 5) 总结
log "Timezone set to: $(cat /etc/timezone 2>/dev/null || echo "${TIMEZONE}")"
if [ $NTP_OK -eq 1 ]; then
  log "NTP: enabled via systemd-timesyncd"
else
  warn "NTP: 未确认启用（容器/权限/网络可导致）。如果是 KVM/裸机应已正常工作。"
fi
systemctl is-enabled nftables >/dev/null 2>&1 && log "nftables: enabled" || warn "nftables: not enabled"

# 6) 可选重启
if [ "${REBOOT}" = "1" ]; then
  log "Rebooting..."
  reboot
fi
