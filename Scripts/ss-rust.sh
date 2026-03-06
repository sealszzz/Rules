#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

: "${SSR_USER:=ssrust}"
: "${SSR_GROUP:=ssrust}"
: "${SSR_STATE_DIR:=/var/lib/ssrust}"
: "${SSR_CONF_DIR:=/etc/ssrust}"
: "${SSR_CONFIG:=${SSR_CONF_DIR}/config.json}"
: "${SSR_BIN:=/usr/local/bin/ssserver}"
: "${SSR_SERVICE:=ssrust}"
: "${SSR_SERVICE_FILE:=/etc/systemd/system/${SSR_SERVICE}.service}"
: "${SSR_DEFAULT_PORT:=8443}"

need_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
}

ensure_deps() {
  local pkgs=() p
  for p in curl xz-utils tar openssl; do
    dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p")
  done
  [ "${#pkgs[@]}" -eq 0 ] || { apt update; apt install -y --no-install-recommends "${pkgs[@]}"; }
}

arch_triple() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
    *)             echo "unsupported" ;;
  esac
}

get_latest_tag() {
  local url
  url="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
    "https://github.com/shadowsocks/shadowsocks-rust/releases/latest")" || return 1
  echo "${url##*/}"
}

ensure_user_and_dirs() {
  getent group "$SSR_GROUP" >/dev/null 2>&1 || groupadd --system "$SSR_GROUP"
  id -u "$SSR_USER" >/dev/null 2>&1 || \
    useradd --system -g "$SSR_GROUP" -M -d "$SSR_STATE_DIR" -s /usr/sbin/nologin "$SSR_USER"

  install -d -o "$SSR_USER" -g "$SSR_GROUP" -m 0755 "$SSR_STATE_DIR"
  install -d -o root -g "$SSR_GROUP" -m 0750 "$SSR_CONF_DIR"
}

write_config_if_missing() {
  [ -f "$SSR_CONFIG" ] && return

  local pass method
  method="2022-blake3-aes-128-gcm"
  pass="$(openssl rand -base64 16 | tr -d '\n')"

  cat >"$SSR_CONFIG" <<EOF
{
  "server": "::",
  "server_port": ${SSR_DEFAULT_PORT},
  "method": "$method",
  "password": "$pass",
  "mode": "tcp_and_udp",
  "timeout": 300,
  "ipv6_first": false
}
EOF
  chown root:"$SSR_GROUP" "$SSR_CONFIG"
  chmod 640 "$SSR_CONFIG"
}

write_service_if_missing() {
  [ -f "$SSR_SERVICE_FILE" ] && return

  cat >"$SSR_SERVICE_FILE" <<EOF
[Unit]
Description=Shadowsocks-Rust Server (2022)
Documentation=https://github.com/shadowsocks/shadowsocks-rust
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
User=$SSR_USER
Group=$SSR_GROUP
Type=simple
UMask=0077
WorkingDirectory=$SSR_STATE_DIR
ExecStart=$SSR_BIN -c $SSR_CONFIG
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
}

install_latest_binary() {
  local tag triple url tmpdir
  tag="$(get_latest_tag)" || { echo "获取最新版 tag 失败"; exit 1; }

  triple="$(arch_triple)"
  [ "$triple" != "unsupported" ] || { echo "当前架构不支持：$(uname -m)（仅支持 x86_64 / aarch64）"; exit 1; }

  url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${tag}/shadowsocks-${tag}.${triple}.tar.xz"
  tmpdir="$(mktemp -d)"

  echo "[*] 下载 ssserver ${tag} ..."
  if ! curl -fsSL "$url" | tar -xJ -C "$tmpdir"; then
    rm -rf "$tmpdir"
    echo "下载或解压失败"
    exit 1
  fi

  [ -f "$tmpdir/ssserver" ] || { rm -rf "$tmpdir"; echo "未在解压目录找到 ssserver"; exit 1; }

  install -m 0755 "$tmpdir/ssserver" "$SSR_BIN"
  rm -rf "$tmpdir"
  echo "✅ 已安装/更新 ssserver 到 $SSR_BIN"
}

restart_service() {
  systemctl daemon-reload
  systemctl enable "$SSR_SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SSR_SERVICE"
}

show_summary() {
  local port method pass ver

  if [ -f "$SSR_CONFIG" ]; then
    port="$(awk -F: '/"server_port"/{gsub(/[^0-9]/,"",$2);print $2;exit}' "$SSR_CONFIG")"
    method="$(awk -F\" '/"method"/{print $4;exit}' "$SSR_CONFIG")"
    pass="$(awk -F\" '/"password"/{print $4;exit}' "$SSR_CONFIG")"
  fi

  : "${port:=$SSR_DEFAULT_PORT}"
  : "${method:=2022-blake3-aes-128-gcm}"
  : "${pass:=<unknown>}"

  if [ -x "$SSR_BIN" ]; then
    ver="$("$SSR_BIN" --version 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//')"
  else
    ver="(ssserver 不存在)"
  fi

  echo
  echo "=== Shadowsocks-Rust ==="
  echo "bin:     $SSR_BIN"
  echo "版本:     $ver"
  echo "端口:     $port"
  echo "加密:     $method"
  echo "密码:     $pass"
}

need_root
ensure_deps
install_latest_binary
ensure_user_and_dirs
write_config_if_missing
write_service_if_missing
restart_service
show_summary
