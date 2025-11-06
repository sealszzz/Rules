#!/usr/bin/env bash
# init-all.sh v1.0 — Debian 13 初始化（TZ/NTP/SSH/BBR/可选XanMod/nftables）
# 环境变量：
#   TIMEZONE=Etc/UTC     时区（默认 Etc/UTC）
#   FORCE_NO_PASSWORD=1  未检测到公钥时也禁用口令登录（不推荐）
#   SKIP_XANMOD=1        跳过 XanMod 安装
#   REBOOT=0             执行完不自动重启

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

: "${TIMEZONE:=Etc/UTC}"
: "${FORCE_NO_PASSWORD:=0}"
: "${SKIP_XANMOD:=0}"
: "${REBOOT:=1}"

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行：sudo $0" >&2; exit 1
  fi
}

have_pubkey() {
  local f
  for f in /root/.ssh/authorized_keys /etc/ssh/authorized_keys/root; do
    [ -s "$f" ] && grep -E -q '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ' "$f" && return 0
  done
  return 1
}

get_ssh_port() {
  if command -v sshd >/dev/null 2>&1; then
    local p
    if p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"; then
      [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] && { echo "$p"; return; }
    fi
  fi
  local g
  g="$(awk '/^[Pp][Oo][Rr][Tt][[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)" || true
  [[ "$g" =~ ^[0-9]+$ ]] && [ "$g" -ge 1 ] && [ "$g" -le 65535 ] && { echo "$g"; return; }
  echo 2222
}

step_update_and_pkgs() {
  echo ">>> 系统更新 & 基础包"
  apt-get update -y
  apt-get -yq full-upgrade
  apt-get -yq install --no-install-recommends \
    ca-certificates gnupg openssl \
    curl wget git \
    python3 python3-venv python3-pip \
    build-essential \
    iproute2 iputils-ping dnsutils \
    tar xz-utils zstd unzip zip \
    jq bc sed \
    rsync lsof \
    tmux htop \
    vim nano
  apt-get -yq clean
}

step_timezone_ntp() {
  echo ">>> 时区与 NTP"
  timedatectl set-timezone "${TIMEZONE}"
  # 避免与其他 NTP 守护冲突
  for svc in chrony ntp; do
    systemctl is-active --quiet "$svc" && systemctl stop "$svc" || true
    systemctl is-enabled --quiet "$svc" && systemctl disable "$svc" || true
  done
  if ! dpkg -s systemd-timesyncd >/dev/null 2>&1; then
    apt-get install -y systemd-timesyncd
  fi
  systemctl unmask systemd-timesyncd.service 2>/dev/null || true
  systemctl enable --now systemd-timesyncd.service
  timedatectl set-ntp true
  timedatectl set-local-rtc 0
  # 等待最多 30 秒显示已同步
  for _ in {1..30}; do
    [ "$(timedatectl show -p NTPSynchronized --value)" = "yes" ] && break
    sleep 1
  done
  timedatectl
}

step_harden_ssh() {
  echo ">>> SSH 加固（禁用口令登录，保留公钥登录）"
  if have_pubkey || [ "$FORCE_NO_PASSWORD" = "1" ]; then
    install -d -m 0700 /etc/ssh/sshd_config.d
    cat >/etc/ssh/sshd_config.d/99-no-password.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF
    if command -v sshd >/dev/null 2>&1; then
      sshd -t && systemctl reload sshd
    else
      echo "注意：未安装 OpenSSH server，已写入配置但未重载。"
    fi
  else
    echo "!!! 未检测到任何 SSH 公钥，已跳过禁用口令登录（避免锁死）。"
    echo "    确认安全后可加 FORCE_NO_PASSWORD=1 再执行。"
  fi
}

step_bbr() {
  echo ">>> BBR + fq"
  install -d -m 0755 /etc/sysctl.d
  cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null || true
}

step_xanmod() {
  [ "$SKIP_XANMOD" = "1" ] && { echo ">>> 跳过 XanMod"; return; }
  echo ">>> XanMod LTS x64v3"
  install -d -m 0755 /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/xanmod-archive-keyring.gpg ]; then
    wget -qO- https://dl.xanmod.org/archive.key | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
  fi
  if [ ! -f /etc/apt/sources.list.d/xanmod-release.list ]; then
    echo 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org trixie main' \
      >/etc/apt/sources.list.d/xanmod-release.list
  fi
  apt-get update -y
  apt-get -y install linux-xanmod-lts-x64v3
  echo ">>> XanMod 安装完成（需重启生效）"
}

step_nftables() {
  echo ">>> nftables（规则逻辑保持不变）"
  local SSH_PORT; SSH_PORT="$(get_ssh_port)"
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
}

final_reboot() {
  if [ "$REBOOT" = "1" ]; then
    echo "[INFO] 5 秒后重启以启用新内核与配置..."
    sleep 5
    systemctl reboot || reboot
  else
    echo "[INFO] 完成（未自动重启；REBOOT=0）。如安装了 XanMod 建议手动重启。"
  fi
}

main() {
  need_root
  step_update_and_pkgs
  step_timezone_ntp
  step_harden_ssh
  step_bbr
  step_xanmod
  step_nftables
  final_reboot
}
main "$@"
