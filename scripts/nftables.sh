#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

NFT_CONF=/etc/nftables.conf
IPFWD_CONF=/etc/sysctl.d/99-nftables-ipforward.conf
TARGET_STATE=/etc/nftables-forward-target

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行。"
    exit 1
  fi
}

exists_cmd() {
  command -v "$1" >/dev/null 2>&1
}

wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 1
  done
}

get_ssh_port() {
  if command -v sshd >/dev/null 2>&1; then
    local p
    p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')" || true
    [[ "$p" =~ ^[0-9]+$ ]] && { echo "$p"; return; }
  fi

  local g
  g="$(awk '/^[Pp][Oo][Rr][Tt][[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)" || true
  [[ "$g" =~ ^[0-9]+$ ]] && echo "$g" || echo 22
}

pause() {
  echo
  read -rp "按回车返回主菜单..." _
}

install_nftables_pkg() {
  if ! exists_cmd nft; then
    wait_for_apt
    apt-get update
    wait_for_apt
    apt-get install -y --no-install-recommends nftables
  fi
  systemctl enable --now nftables >/dev/null 2>&1 || true
}

valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  local IFS=.
  local a b c d
  read -r a b c d <<<"$ip"
  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    [ "$n" -ge 0 ] && [ "$n" -le 255 ] || return 1
  done
  return 0
}

get_saved_target_ip() {
  if [ -f "$TARGET_STATE" ]; then
    tr -d '[:space:]' <"$TARGET_STATE"
  fi
}

get_current_target_ip() {
  if [ -f "$NFT_CONF" ]; then
    awk '/dnat to /{sub(/:443.*/, "", $NF); print $NF; exit}' "$NFT_CONF" 2>/dev/null || true
  fi
}

has_tcp_forward() {
  [ -f "$NFT_CONF" ] && grep -Eq '^[[:space:]]*tcp dport 443 dnat to ' "$NFT_CONF"
}

has_udp_forward() {
  [ -f "$NFT_CONF" ] && grep -Eq '^[[:space:]]*udp dport 443 dnat to ' "$NFT_CONF"
}

prompt_target_ip() {
  local cur saved ip
  cur="$(get_current_target_ip)"
  saved="$(get_saved_target_ip)"

  while true; do
    if [ -n "$cur" ]; then
      read -rp "请输入要转发到的 IPv4 地址 [当前: $cur]: " ip
      ip="${ip:-$cur}"
    elif [ -n "$saved" ]; then
      read -rp "请输入要转发到的 IPv4 地址 [上次: $saved]: " ip
      ip="${ip:-$saved}"
    else
      read -rp "请输入要转发到的 IPv4 地址: " ip
    fi

    ip="$(echo "${ip:-}" | tr -d '[:space:]')"

    if valid_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi

    echo "IPv4 地址格式无效，请重试。"
  done
}

write_normal_conf() {
  local ssh_port="$1"

  cat >"$NFT_CONF" <<EOF2
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
    elements = { 80, 443, ${ssh_port} }
  }

  set udp_allow {
    type inet_service
    flags interval
    elements = { 443 }
  }

  chain input {
    type filter hook input priority filter; policy drop;

    ip  saddr @blacklist4 counter drop
    ip6 saddr @blacklist6 counter drop

    ct state { established, related } accept

    iif lo accept

    ip protocol icmp accept
    meta l4proto ipv6-icmp accept

    meta nfproto ipv4 tcp flags syn tcp dport != @tcp_allow ct state new \
      ip saddr != 0.0.0.0 add @blacklist4 { ip saddr timeout 7d } counter drop
    meta nfproto ipv6 tcp flags syn tcp dport != @tcp_allow ct state new \
      ip6 saddr != :: add @blacklist6 { ip6 saddr timeout 7d } counter drop

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
EOF2
}

write_forward_conf() {
  local ssh_port="$1"
  local target_ip="$2"
  local forward_mode="$3"
  local prerouting_rules postrouting_rules forward_rules
  local tcp_allow_elements udp_accept_rule

  case "$forward_mode" in
    both)
      prerouting_rules="    tcp dport 443 dnat to ${target_ip}:443
    udp dport 443 dnat to ${target_ip}:443"
      postrouting_rules="    ip daddr ${target_ip} tcp dport 443 masquerade
    ip daddr ${target_ip} udp dport 443 masquerade"
      forward_rules="    ip daddr ${target_ip} tcp dport 443 accept
    ip daddr ${target_ip} udp dport 443 accept"
      tcp_allow_elements="80, ${ssh_port}"
      udp_accept_rule=""
      ;;
    tcp)
      prerouting_rules="    tcp dport 443 dnat to ${target_ip}:443"
      postrouting_rules="    ip daddr ${target_ip} tcp dport 443 masquerade"
      forward_rules="    ip daddr ${target_ip} tcp dport 443 accept"
      tcp_allow_elements="80, ${ssh_port}"
      udp_accept_rule="    udp dport 443 accept"
      ;;
    udp)
      prerouting_rules="    udp dport 443 dnat to ${target_ip}:443"
      postrouting_rules="    ip daddr ${target_ip} udp dport 443 masquerade"
      forward_rules="    ip daddr ${target_ip} udp dport 443 accept"
      tcp_allow_elements="80, 443, ${ssh_port}"
      udp_accept_rule=""
      ;;
    *)
      echo "无效转发模式: $forward_mode" >&2
      return 1
      ;;
  esac

  cat >"$NFT_CONF" <<EOF2
flush ruleset

table ip nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
${prerouting_rules}
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
${postrouting_rules}
  }
}

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
    elements = { ${tcp_allow_elements} }
  }

  chain input {
    type filter hook input priority filter; policy drop;

    ip  saddr @blacklist4 counter drop
    ip6 saddr @blacklist6 counter drop

    ct state { established, related } accept

    iif lo accept

    ip protocol icmp accept
    meta l4proto ipv6-icmp accept

    meta nfproto ipv4 tcp flags syn tcp dport != @tcp_allow ct state new \
      ip saddr != 0.0.0.0 add @blacklist4 { ip saddr timeout 7d } counter drop
    meta nfproto ipv6 tcp flags syn tcp dport != @tcp_allow ct state new \
      ip6 saddr != :: add @blacklist6 { ip6 saddr timeout 7d } counter drop

    tcp dport @tcp_allow accept
${udp_accept_rule}
  }

  chain forward {
    type filter hook forward priority filter; policy drop;

    ct state { established, related } accept
${forward_rules}
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
EOF2
}

apply_normal_rules() {
  local ssh_port
  ssh_port="$(get_ssh_port)"

  install_nftables_pkg
  write_normal_conf "$ssh_port"
  nft -c -f "$NFT_CONF"
  nft -f "$NFT_CONF"

  rm -f "$IPFWD_CONF"
  sysctl -w net.ipv4.ip_forward=0 >/dev/null
  systemctl enable --now nftables >/dev/null 2>&1 || true

  echo "[OK] 已应用正常模式。"
  echo "SSH 端口: $ssh_port"
  echo "本机开放: TCP 80/443、UDP 443、SSH"
}

apply_forward_rules() {
  local forward_mode="$1"
  local ssh_port target_ip mode_text
  ssh_port="$(get_ssh_port)"

  if [ "$ssh_port" = "443" ]; then
    echo "[ERROR] 当前 SSH 端口为 443，启用 443 DNAT 会导致 IPv4 SSH 被转发，已取消。"
    return 0
  fi

  case "$forward_mode" in
    both) mode_text="TCP + UDP" ;;
    tcp)  mode_text="仅 TCP" ;;
    udp)  mode_text="仅 UDP" ;;
    *)
      echo "无效转发模式: $forward_mode"
      return 0
      ;;
  esac

  target_ip="$(prompt_target_ip)"

  install_nftables_pkg
  write_forward_conf "$ssh_port" "$target_ip" "$forward_mode"
  nft -c -f "$NFT_CONF"
  nft -f "$NFT_CONF"

  printf 'net.ipv4.ip_forward=1\n' >"$IPFWD_CONF"
  echo "$target_ip" >"$TARGET_STATE"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  systemctl enable --now nftables >/dev/null 2>&1 || true

  echo "[OK] 已切换到 443 转发模式（${mode_text}）。"
  echo "SSH 端口: $ssh_port"
  echo "转发目标: $target_ip:443"
  case "$forward_mode" in
    both)
      echo "本机保持: TCP 80 + SSH；TCP/UDP 443 转发"
      ;;
    tcp)
      echo "本机保持: TCP 80 + SSH + UDP 443；仅 TCP 443 转发"
      ;;
    udp)
      echo "本机保持: TCP 80/443 + SSH；仅 UDP 443 转发"
      ;;
  esac
}

clear_blacklist() {
  if ! exists_cmd nft; then
    echo "nft 未安装。"
    return 0
  fi

  if ! nft list table inet filter >/dev/null 2>&1; then
    echo "当前不存在 inet filter 表，无黑名单可清空。"
    return 0
  fi

  local cleared=0

  if nft list set inet filter blacklist4 >/dev/null 2>&1; then
    nft flush set inet filter blacklist4
    echo "[OK] 已清空 IPv4 黑名单。"
    cleared=1
  fi

  if nft list set inet filter blacklist6 >/dev/null 2>&1; then
    nft flush set inet filter blacklist6
    echo "[OK] 已清空 IPv6 黑名单。"
    cleared=1
  fi

  if [ "$cleared" -eq 0 ]; then
    echo "当前未找到 blacklist4 / blacklist6。"
  fi
}

current_mode() {
  local tcp=0 udp=0

  has_tcp_forward && tcp=1 || true
  has_udp_forward && udp=1 || true

  if [ "$tcp" -eq 1 ] && [ "$udp" -eq 1 ]; then
    echo "443 TCP+UDP 转发模式"
  elif [ "$tcp" -eq 1 ]; then
    echo "443 TCP 转发模式"
  elif [ "$udp" -eq 1 ]; then
    echo "443 UDP 转发模式"
  elif [ -f "$NFT_CONF" ]; then
    echo "正常模式"
  else
    echo "未配置"
  fi
}

show_status() {
  local ssh_port target_ip saved_ip tcp_status="本机" udp_status="本机"
  ssh_port="$(get_ssh_port)"
  target_ip="$(get_current_target_ip)"
  saved_ip="$(get_saved_target_ip)"

  has_tcp_forward && tcp_status="转发" || true
  has_udp_forward && udp_status="转发" || true

  echo "============== 当前状态 =============="
  echo "模式: $(current_mode)"
  echo "SSH 端口: $ssh_port"

  if [ -n "$target_ip" ]; then
    echo "当前转发目标: ${target_ip}:443"
    echo "TCP 443: $tcp_status"
    echo "UDP 443: $udp_status"
    echo "TCP 80: 本机"
    echo "SSH: 本机"
    echo "IPv6: 被转发的 443 协议不在本机开放；未转发的协议保持本机开放"
  else
    echo "当前转发目标: 未设置"
    if [ -n "$saved_ip" ]; then
      echo "上次转发目标: ${saved_ip}:443"
    fi
  fi

  echo "nftables: $(systemctl is-enabled nftables 2>/dev/null || echo unknown) / $(systemctl is-active nftables 2>/dev/null || echo inactive)"
  echo "ip_forward: $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
  echo "配置文件: $NFT_CONF"
  echo "======================================"
}

show_rules() {
  echo "============== nft ruleset =============="
  if exists_cmd nft; then
    nft list ruleset || true
  else
    echo "nft 未安装。"
  fi
  echo "========================================="
}

main_menu() {
  while true; do
    clear
    cat <<MENU
==================== nftables 菜单 ====================
当前模式: $(current_mode)
SSH 端口: $(get_ssh_port)

 1) 正常模式（本机 TCP 80/443 + UDP 443 + SSH）
 2) 转发 TCP + UDP 443
 3) 仅转发 TCP 443
 4) 仅转发 UDP 443
 5) 查看当前规则
 6) 查看当前状态
 7) 清空黑名单
 0) 退出
======================================================
MENU

    read -rp "请输入选项: " choice
    echo

    case "${choice:-}" in
      1)
        apply_normal_rules
        pause
        ;;
      2)
        apply_forward_rules both
        pause
        ;;
      3)
        apply_forward_rules tcp
        pause
        ;;
      4)
        apply_forward_rules udp
        pause
        ;;
      5)
        show_rules
        pause
        ;;
      6)
        show_status
        pause
        ;;
      7)
        clear_blacklist
        pause
        ;;
      0|q|Q|quit|exit)
        echo "Bye."
        exit 0
        ;;
      *)
        echo "无效输入。"
        pause
        ;;
    esac
  done
}

need_root
exists_cmd systemctl || { echo "需要 systemd 环境"; exit 1; }
main_menu
