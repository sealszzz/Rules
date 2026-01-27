#!/usr/bin/env bash
set -euo pipefail

: "${TT_PORT:=443}"
: "${TT_HOSTNAME:=example.com}"
: "${TT_ALLOWED_SNI:=www.example.com}"

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

TT_USER="trusttunnel"
TT_GROUP="trusttunnel"

TT_BIN="/usr/local/bin/trusttunnel"
TT_STATE_DIR="/var/lib/trusttunnel"
TT_CONF_DIR="/etc/trusttunnel"
TT_CONF="${TT_CONF_DIR}/trusttunnel.toml"

TT_SVC_NAME="trusttunnel"
TT_SVC="/etc/systemd/system/${TT_SVC_NAME}.service"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  curl ca-certificates tar xz-utils openssl

[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

getent group "$TT_GROUP" >/dev/null || groupadd --system "$TT_GROUP"
id -u "$TT_USER" >/dev/null 2>&1 || \
  useradd --system -g "$TT_GROUP" -M -d "$TT_STATE_DIR" -s /usr/sbin/nologin "$TT_USER"

install -d -o "$TT_USER" -g "$TT_GROUP" -m 750 "$TT_STATE_DIR"
install -d -o root -g "$TT_GROUP" -m 750 "$TT_CONF_DIR"

get_tt_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
      https://github.com/TrustTunnel/TrustTunnel/releases/latest)" || return 1
  printf '%s\n' "${u##*/}"
}

pick_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) echo "unsupported arch: $(uname -m)"; exit 1 ;;
  esac
}

install_tt_release_minimal() {
  local tag arch asset base tmpd unpackd ep

  tag="$(get_tt_tag)"
  [ -n "$tag" ] || { echo "FATAL: cannot resolve latest tag"; exit 1; }

  arch="$(pick_arch)"
  asset="trusttunnel-${tag}-linux-${arch}.tar.gz"
  base="https://github.com/TrustTunnel/TrustTunnel/releases/download/${tag}"

  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' RETURN

  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.tgz" "${base}/${asset}"
  unpackd="$tmpd/unpack"
  mkdir -p "$unpackd"
  tar -xzf "$tmpd/pkg.tgz" -C "$unpackd"

  ep="$(find "$unpackd" -type f -name trusttunnel_endpoint -perm -u+x | head -n1 || true)"
  [ -n "$ep" ] || { echo "FATAL: trusttunnel_endpoint not found in archive"; exit 1; }

  install -m 0755 "$ep" "$TT_BIN"

  trap - RETURN
  printf '%s\n' "$tag"
}

gen_user_pass() {
  local u p
  u="tt_$(openssl rand -hex 4)"
  p="$(openssl rand -hex 16)"
  printf '%s\n' "$u"
  printf '%s\n' "$p"
}

TAG="$(install_tt_release_minimal)"

if [ ! -f "$TT_CONF" ]; then
  mapfile -t UP < <(gen_user_pass)
  TT_USERNAME="${UP[0]}"
  TT_PASSWORD="${UP[1]}"

  cat >"$TT_CONF" <<EOF
listen_address = "[::]:${TT_PORT}"

[[client]]
username = "${TT_USERNAME}"
password = "${TT_PASSWORD}"

# rules_file = "rules.toml"

# "vpn.toml"
ipv6_available = true
allow_private_network_connections = false
tls_handshake_timeout_secs = 10
client_listener_timeout_secs = 600
connection_establishment_timeout_secs = 30
tcp_connections_timeout_secs = 604800
udp_connections_timeout_secs = 300
speedtest_enable = false

[forward_protocol]
direct = {}
[forward_protocol.direct]

# Reverse proxy settings (optional)
# [reverse_proxy]
# server_address = "127.0.0.1:8080"
# path_mask = "/api"
# h3_backward_compatibility = false

[listen_protocols]

[listen_protocols.http1]
upload_buffer_size = 32768

[listen_protocols.http2]
initial_connection_window_size = 8388608
initial_stream_window_size = 131072
max_concurrent_streams = 1000
max_frame_size = 16384
header_table_size = 65536

[listen_protocols.quic]
recv_udp_payload_size = 1350
send_udp_payload_size = 1350
initial_max_data = 104857600
max_stream_data_bidi_local = 1048576
max_stream_data_bidi_remote = 1048576
max_stream_data_uni = 1048576
max_streams_bidi = 4096
max_streams_uni = 4096
max_connection_window = 25165824
max_stream_window = 16777216
disable_active_migration = true
enable_early_data = true
message_queue_capacity = 4096

# # The ICMP forwarding settings.
# # Setting up this feature requires superuser rights on some systems.
# [icmp]
# # The name of a network interface to bind the outbound ICMP socket to
# interface_name = "eth0"
# # Timeout of tunneled ICMP requests
# request_timeout_secs = 3
# # The capacity of the ICMP multiplexer received messages queue.
# # Decreasing it may cause packet dropping in case the multiplexer cannot keep up the pace.
# # Increasing it may lead to high memory consumption.
# # Each client has its own queue.
# recv_message_queue_capacity = 256
# # The metrics gathering request handler settings
# [metrics]
# # The address to listen on for settings export requests
# address = "0.0.0.0:1987"
# # Timeout of a metrics request
# request_timeout_secs = 3

# "hosts.toml"
[[main_hosts]]
hostname = "${TT_HOSTNAME}"
cert_chain_path = "${CERT}"
private_key_path = "${KEY}"
allowed_sni = ["${TT_ALLOWED_SNI}"]

ping_hosts = []
[[ping_hosts]]
# hostname = "ping.vpn.example.com"
# cert_chain_path = "certs/cert.pem"
# private_key_path = "certs/key.pem"

speedtest_hosts = []
[[speedtest_hosts]]
# hostname = "speed.vpn.example.com"
# cert_chain_path = "certs/cert.pem"
# private_key_path = "certs/key.pem"

reverse_proxy_hosts = []
# [[reverse_proxy_hosts]]
# hostname = "api.example.com"
# cert_chain_path = "certs/cert.pem"
# private_key_path = "certs/key.pem"
EOF

  chown root:"$TT_GROUP" "$TT_CONF"
  chmod 640 "$TT_CONF"

  echo "Generated credentials (in ${TT_CONF}):"
  echo "  username: ${TT_USERNAME}"
  echo "  password: ${TT_PASSWORD}"
fi

if [ ! -f "$TT_SVC" ]; then
  cat >"$TT_SVC" <<EOF
[Unit]
Description=TrustTunnel endpoint
Documentation=https://github.com/TrustTunnel/TrustTunnel
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${TT_USER}
Group=${TT_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${TT_STATE_DIR}
ExecStart=${TT_BIN} ${TT_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$TT_SVC"
fi

systemctl daemon-reload
if systemctl is-enabled "$TT_SVC_NAME" >/dev/null 2>&1; then
  systemctl restart "$TT_SVC_NAME"
else
  systemctl enable --now "$TT_SVC_NAME" >/dev/null 2>&1 || true
fi

VER="$("$TT_BIN" --version 2>/dev/null || "$TT_BIN" -V 2>/dev/null || true)"
echo "trusttunnel tag: ${TAG:-unknown}"
echo "trusttunnel bin: ${VER:-unknown}"
echo "config: ${TT_CONF}"
