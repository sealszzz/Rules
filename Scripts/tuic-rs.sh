#!/usr/bin/env bash
set -euo pipefail

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${UUID:=}"
: "${PASS:=}"
: "${TUIC_TAG:=}"

APP_USER="tuic-rs"
APP_GROUP="tuic-rs"
APP_STATE_DIR="/var/lib/tuic-rs"
APP_CONF_DIR="/etc/tuic-rs"
APP_CONF_FILE="${APP_CONF_DIR}/config.json"
APP_BIN="/usr/local/bin/tuic-rs"
APP_SERVICE_NAME="tuic-rs"
APP_SERVICE="/etc/systemd/system/${APP_SERVICE_NAME}.service"
APP_REPO="sealszzz/Rules"
APP_ASSET_BASENAME="tuic-rs"
APP_BIN_NAME="tuic-rs"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates tar xz-utils openssl jq

[ -r "$CERT" ] || { echo "FATAL: missing $CERT" >&2; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY" >&2; exit 1; }

getent group "$APP_GROUP" >/dev/null || groupadd --system "$APP_GROUP"
id -u "$APP_USER" >/dev/null 2>&1 || useradd --system -g "$APP_GROUP" -M -d "$APP_STATE_DIR" -s /usr/sbin/nologin "$APP_USER"

install -d -o "$APP_USER" -g "$APP_GROUP" -m 750 "$APP_STATE_DIR"
install -d -o root -g "$APP_GROUP" -m 750 "$APP_CONF_DIR"

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
  amd64|x86_64)  ASSET_ARCH="linux-amd64" ;;
  arm64|aarch64) ASSET_ARCH="linux-arm64" ;;
  *) echo "FATAL: unsupported arch: $(dpkg --print-architecture 2>/dev/null || uname -m)" >&2; exit 1 ;;
esac

find_release_tag_for_asset() {
  local repo="$1"
  local prefix="$2"
  local api

  api="https://api.github.com/repos/${repo}/releases?per_page=50"

  curl -fsSL "$api" | jq -r --arg prefix "$prefix" '
    map(select(any(.assets[]?; (.name | startswith($prefix) and endswith(".tar.gz")))))
    | .[0].tag_name // empty
  '
}

install_release_asset() {
  local repo="$1"
  local tag="$2"
  local base_name="$3"
  local bin_name="$4"
  local asset url tmpd bin

  asset="${base_name}-${ASSET_ARCH}-${tag}.tar.gz"
  url="https://github.com/${repo}/releases/download/${tag}/${asset}"

  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' RETURN

  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.tgz" "$url"
  mkdir -p "$tmpd/unpack"
  tar -xzf "$tmpd/pkg.tgz" -C "$tmpd/unpack"

  if [ -f "$tmpd/unpack/$bin_name" ]; then
    bin="$tmpd/unpack/$bin_name"
  else
    bin="$(find "$tmpd/unpack" -maxdepth 3 -type f -name "$bin_name" | head -n1 || true)"
  fi

  [ -n "$bin" ] || { echo "FATAL: ${bin_name} binary not found" >&2; exit 1; }

  install -m 0755 "$bin" "$APP_BIN"
  trap - RETURN
}

gen_uuid() {
  cat /proc/sys/kernel/random/uuid
}

gen_pass() {
  openssl rand -hex 16
}

if [ -z "$TUIC_TAG" ]; then
  TUIC_TAG="$(find_release_tag_for_asset "$APP_REPO" "${APP_ASSET_BASENAME}-${ASSET_ARCH}-")"
fi

[ -n "$TUIC_TAG" ] || { echo "FATAL: failed to find a tuic-rs release for ${ASSET_ARCH}" >&2; exit 1; }

install_release_asset "$APP_REPO" "$TUIC_TAG" "$APP_ASSET_BASENAME" "$APP_BIN_NAME"

command -v "$APP_BIN" >/dev/null 2>&1 || { echo "FATAL: ${APP_BIN} not found" >&2; exit 1; }

if [ ! -f "$APP_CONF_FILE" ]; then
  [ -n "$UUID" ] || UUID="$(gen_uuid)"
  [ -n "$PASS" ] || PASS="$(gen_pass)"

  cat >"$APP_CONF_FILE" <<EOF
{
  "listen": "[::]:443",
  "zero_rtt_mode": "auth",
  "cert": "${CERT}",
  "key": "${KEY}",
  "users": [
    {
      "uuid": "${UUID}",
      "password": "${PASS}"
    }
  ],
  "alpn": [
    "h3"
  ],
  "congestion_control": "bbr",
  "ip_preference": "v4v6",
  "log_level": "info",
  "max_idle_secs": 200,
  "keepalive_secs": 20,
  "tcp_connect_timeout_secs": 8,
  "tcp_connect_race_stagger_ms": 150,
  "dns_cache_ttl_secs": 60,
  "auth_timeout_secs": 5,
  "max_handshakes": 64,
  "max_connections": 256,
  "udp_frag_max_inflight": 128,
  "udp_frag_max_buffered_bytes": 1048576,
  "udp_frag_ttl_secs": 5,
  "quic_socket_recv_buffer": 2097152,
  "quic_socket_send_buffer": 2097152,
  "relay_udp_socket_recv_buffer": 131072,
  "relay_udp_socket_send_buffer": 131072,
  "quic_datagram_receive_buffer": 131072,
  "quic_datagram_send_buffer": 131072,
  "quic_send_window": 2097152,
  "quic_recv_window": 2097152,
  "quic_stream_recv_window": 262144,
  "quic_max_concurrent_bidi_streams": 1024,
  "quic_max_concurrent_uni_streams": 1024,
  "quic_initial_mtu": 1400,
  "quic_min_mtu": 1200,
  "max_udp_assocs_per_session": 16,
  "quic_stateless_retry": true
}
EOF

  jq empty "$APP_CONF_FILE" >/dev/null 2>&1 || { echo "FATAL: invalid json generated" >&2; cat "$APP_CONF_FILE" >&2; exit 1; }
  chown root:"$APP_GROUP" "$APP_CONF_FILE"
  chmod 640 "$APP_CONF_FILE"
fi

if [ ! -f "$APP_SERVICE" ]; then
  cat >"$APP_SERVICE" <<EOF
[Unit]
Description=TUIC Rust Server
Documentation=https://github.com/${APP_REPO}/releases
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${APP_USER}
Group=${APP_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${APP_STATE_DIR}
ExecStart=${APP_BIN} ${APP_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$APP_SERVICE"
fi

systemctl daemon-reload
if systemctl is-enabled --quiet "$APP_SERVICE_NAME"; then
  systemctl restart "$APP_SERVICE_NAME"
else
  systemctl enable --now "$APP_SERVICE_NAME"
fi

BIN_VER="$("$APP_BIN" --version 2>/dev/null || true)"
SHOW_UUID="$(jq -r '.users[0].uuid // empty' "$APP_CONF_FILE" 2>/dev/null || true)"
SHOW_PASS="$(jq -r '.users[0].password // empty' "$APP_CONF_FILE" 2>/dev/null || true)"

echo "app: tuic-rs"
echo "tag: ${TUIC_TAG:-unknown}"
echo "bin: ${BIN_VER:-unknown}"
echo "config: ${APP_CONF_FILE}"
echo "uuid: ${SHOW_UUID:-unknown}"
echo "password: ${SHOW_PASS:-unknown}"
