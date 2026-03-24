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
  [[ "$g" =~ ^[0-9]+$ ]] && echo "$g" || echo 8888
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
    tr -d '[:space:]' < "$TARGET_STATE"
  fi
}

get_current_target_ip() {
  if [ -f "$NFT_CONF" ]; then
    awk '/dnat to /{sub(/:443.*/, "", $NF); print $NF; exit}' "$NFT_CONF" 2>/dev/null || true
  fi
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

  cat >"$NFT_CONF" <<EOF
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;

    ct state { established, related } accept
    iif lo accept

    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept

    tcp dport { 80, 443, ${ssh_port} } accept
    udp dport 443 accept
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
EOF
}

write_forward_conf() {
  local ssh_port="$1"
  local target_ip="$2"

  cat >"$NFT_CONF" <<EOF
flush ruleset

table ip nat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    tcp dport 443 dnat to ${target_ip}:443
    udp dport 443 dnat to ${target_ip}:443
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip daddr ${target_ip} tcp dport 443 masquerade
    ip daddr ${target_ip} udp dport 443 masquerade
  }
}

table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;

    ct state { established, related } accept
    iif lo accept

    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept

    tcp dport { 80, 443, ${ssh_port} } accept
    udp dport 443 accept
  }

  chain forward {
    type filter hook forward priority filter; policy drop;

    ct state { established, related } accept
    ip daddr ${target_ip} tcp dport 443 accept
    ip daddr ${target_ip} udp dport 443 accept
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
EOF
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

  echo "[OK] 已切换到正常模式。"
  echo "SSH 端口: $ssh_port"
}

apply_forward_rules() {
  local ssh_port target_ip
  ssh_port="$(get_ssh_port)"
  target_ip="$(prompt_target_ip)"

  install_nftables_pkg
  write_forward_conf "$ssh_port" "$target_ip"
  nft -c -f "$NFT_CONF"
  nft -f "$NFT_CONF"

  printf 'net.ipv4.ip_forward=1\n' >"$IPFWD_CONF"
  echo "$target_ip" >"$TARGET_STATE"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  systemctl enable --now nftables >/dev/null 2>&1 || true

  echo "[OK] 已切换到 443 转发模式。"
  echo "SSH 端口: $ssh_port"
  echo "转发目标: $target_ip:443"
}

current_mode() {
  if [ -f "$NFT_CONF" ] && grep -q 'dnat to ' "$NFT_CONF"; then
    echo "443 转发模式"
  elif [ -f "$NFT_CONF" ]; then
    echo "正常模式"
  else
    echo "未配置"
  fi
}

show_status() {
  local ssh_port target_ip
  ssh_port="$(get_ssh_port)"
  target_ip="$(get_current_target_ip)"

  echo "============== 当前状态 =============="
  echo "模式: $(current_mode)"
  echo "SSH 端口: $ssh_port"
  if [ -n "$target_ip" ]; then
    echo "当前转发目标: ${target_ip}:443"
  else
    echo "当前转发目标: 未设置"
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

 1) 安装/重装正常 nftables
 2) 切换到 443 转发模式（现场输入目标 IPv4）
 3) 切回正常模式
 4) 查看当前规则
 5) 查看当前状态
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
        apply_forward_rules
        pause
        ;;
      3)
        apply_normal_rules
        pause
        ;;
      4)
        show_rules
        pause
        ;;
      5)
        show_status
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
