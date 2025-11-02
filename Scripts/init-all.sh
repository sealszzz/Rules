#!/usr/bin/env bash
# init-all.sh — 一把梭初始化（含 nftables）
# 步骤：系统更新 -> 禁用口令登录(安全检测) -> BBR -> XanMod -> 你的 nftables -> 重启
# 环境变量：
#   FORCE_NO_PASSWORD=1  强制关闭口令登录（即使未检测到公钥，不推荐）
#   SKIP_XANMOD=1        跳过 XanMod 安装
#   REBOOT=0             结束不自动重启

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

: "${FORCE_NO_PASSWORD:=0}"
: "${SKIP_XANMOD:=0}"
: "${REBOOT:=1}"

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行：sudo $0"; exit 1
  fi
}

have_pubkey() {
  local f
  for f in /root/.ssh/authorized_keys /etc/ssh/authorized_keys/root; do
    [ -s "$f" ] && grep -E -q '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ' "$f" && return 0
  done
  return 1
}

step_update_and_pkgs() {
  echo ">>> 系统更新 & 基础包安装"
  apt-get update
  apt-get -yq full-upgrade
  # 注意：不装 nftables，这一步留给你的代码段来安装与启用
  apt-get -yq install --no-install-recommends \
    build-essential git curl wget nano vim unzip zip htop ca-certificates gnupg \
    dnsutils net-tools openssl python3-pip python3-venv usrmerge jq bc sed \
    iproute2 iputils-ping tar xz-utils bzip2 zstd tmux rsync lsof
  apt-get -yq autoremove --purge
  apt-get -yq clean
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
    sshd -t && systemctl reload sshd
    echo "当前关键项："
    sshd -T | egrep -i '^(passwordauthentication|pubkeyauthentication|permitrootlogin)\b' || true
  else
    echo "!!! 未检测到任何 SSH 公钥，跳过禁用口令登录（避免锁死）。"
    echo "    如确认安全，可加 FORCE_NO_PASSWORD=1 再执行。"
  fi
}

step_bbr() {
  echo ">>> 配置 BBR + FQ"
  install -d -m 0755 /etc/sysctl.d
  cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null || true
  sysctl net.core.default_qdisc || true
  sysctl net.ipv4.tcp_congestion_control || true
}

step_xanmod() {
  [ "$SKIP_XANMOD" = "1" ] && { echo ">>> 跳过 XanMod 安装（SKIP_XANMOD=1）"; return; }
  echo ">>> 配置 XanMod 仓库并安装 LTS x64v3"
  install -d -m 0755 /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/xanmod-archive-keyring.gpg ]; then
    wget -qO- https://dl.xanmod.org/archive.key | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
  fi
  if [ ! -f /etc/apt/sources.list.d/xanmod-release.list ]; then
    echo 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org trixie main' \
      >/etc/apt/sources.list.d/xanmod-release.list
  fi
  apt-get update
  apt-get -y install linux-xanmod-lts-x64v3
  echo ">>> XanMod 安装完成（重启后生效）"
}

# ===== nftables 代码 =====
step_nftables_verbatim() {
#!/usr/bin/env bash
set -euo pipefail

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
  set blacklist4 { type ipv4_addr; timeout 7d; size 65535; gc-interval 5m; }
  set blacklist6 { type ipv6_addr; timeout 7d; size 65535; gc-interval 5m; }

  # 允许端口（按你的环境）
  set tcp_allow { type inet_service; elements = { ${SSH_PORT}, 80, 443, 4443, 8443, 8448 }; }
  set udp_allow { type inet_service; elements = { 443, 4443, 8443, 8448 }; }

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
    tcp flags & syn == syn tcp dport != @tcp_allow ct state new ip  saddr != 0.0.0.0 add @blacklist4 { ip saddr }  counter drop
    tcp flags & syn == syn tcp dport != @tcp_allow ct state new ip6 saddr != ::      add @blacklist6 { ip6 saddr } counter drop

    #   UDP：未开放端口仅丢弃，不加黑
    udp dport != @udp_allow ct state new counter drop

    # 允许端口的新建必须是 SYN（仅作用 TCP，不影响 QUIC/UDP）
    tcp dport @tcp_allow ct state new tcp flags & (fin|syn|rst|ack) != syn counter drop

    # 4) 最终放行允许端口
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
echo "  手动拉黑(IPv4)：nft add element inet filter blacklist4 { 198.51.100.10 }"
echo "  解除拉黑(IPv4)：nft delete element inet filter blacklist4 { 198.51.100.10 }"
echo "  查看集合：nft list set inet filter blacklist4 ; nft list set inet filter blacklist6"
}
# ===== nftables 代码结束 =====

final_reboot() {
  if [ "$REBOOT" = "1" ]; then
    echo "[INFO] 5 秒后重启以启用新内核与配置..."
    sleep 5
    systemctl reboot || reboot
  else
    echo "[INFO] 已完成所有步骤（未自动重启；REBOOT=0）。建议手动执行：reboot"
  fi
}

main() {
  need_root
  step_update_and_pkgs
  step_harden_ssh
  step_bbr
  step_xanmod
  step_nftables_verbatim
  final_reboot
}

main "$@"
