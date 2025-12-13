#!/usr/bin/env bash
# tuic-min: stable latest via 302, bin-only upgrade, create config/service once
set -euo pipefail

: "${TUIC_PORT:=8443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${TUIC_TAG:=}"

TUIC_USER="tuic"
TUIC_GROUP="tuic"

TUIC_STATE_DIR="/var/lib/tuic"
TUIC_CONF_DIR="/etc/tuic"
TUIC_CONF_FILE="${TUIC_CONF_DIR}/config.toml"

TUIC_BIN="/usr/local/bin/tuic-server"
TUIC_SERVICE_NAME="tuic-server"
TUIC_SERVICE="/etc/systemd/system/${TUIC_SERVICE_NAME}.service"

export DEBIAN_FRONTEND=noninteractive

apt update >/dev/null
apt install -y --no-install-recommends curl ca-certificates uuid-runtime openssl iproute2 >/dev/null

[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

getent group "$TUIC_GROUP" >/dev/null || groupadd --system "$TUIC_GROUP"
id -u "$TUIC_USER" >/dev/null 2>&1 || \
  useradd --system -g "$TUIC_GROUP" -M -d "$TUIC_STATE_DIR" -s /usr/sbin/nologin "$TUIC_USER"

install -d -o "$TUIC_USER" -g "$TUIC_GROUP" -m 750 "$TUIC_STATE_DIR"
install -d -o root        -g "$TUIC_GROUP" -m 750 "$TUIC_CONF_DIR"

get_latest_tag_302() {
  if [ -n "${TUIC_TAG}" ]; then
    printf '%s\n' "$TUIC_TAG"
    return 0
  fi
  local final
  final="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
    https://github.com/Itsusinn/tuic/releases/latest)" || return 1
  printf '%s\n' "${final##*/}"
}

TAG="$(get_latest_tag_302)" || { echo "FATAL: cannot resolve latest tag"; exit 1; }

case "$(uname -m)" in
  x86_64|amd64)  ARK="x86_64" ;;
  aarch64|arm64) ARK="aarch64" ;;
  *) echo "FATAL: unsupported arch"; exit 1 ;;
esac

ASSET="tuic-server-${ARK}-linux"
URL="https://github.com/Itsusinn/tuic/releases/download/${TAG}/${ASSET}"

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
curl -fL --retry 3 --retry-delay 1 -o "$tmpd/$ASSET" "$URL"
chmod +x "$tmpd/$ASSET"
install -m 0755 "$tmpd/$ASSET" "$TUIC_BIN"

if [ ! -f "$TUIC_CONF_FILE" ]; then
  TUIC_UUID="$(uuidgen)"
  TUIC_PASS="$(openssl rand -hex 16)"

  cat >"$TUIC_CONF_FILE" <<EOF
log_level = "warn"
server = "[::]:${TUIC_PORT}"
udp_relay_ipv6 = true
zero_rtt_handshake = false
dual_stack = false
auth_timeout = "8s"

[users]
"${TUIC_UUID}" = "${TUIC_PASS}"

[tls]
self_sign = false
certificate = "${CERT}"
private_key = "${KEY}"
alpn = ["h3"]

[quic]
max_idle_time = "30s"

[quic.congestion_control]
controller = "bbr"

[experimental]
drop_loopback = true
drop_private = true

[outbound.default]
type = "direct"
ip_mode = "v4first"
EOF

  chown root:"$TUIC_GROUP" "$TUIC_CONF_FILE"
  chmod 640 "$TUIC_CONF_FILE"
fi

if [ ! -f "$TUIC_SERVICE" ]; then
  cat >"$TUIC_SERVICE" <<EOF
[Unit]
Description=TUIC Server
After=network-online.target
Wants=network-online.target

[Service]
User=${TUIC_USER}
Group=${TUIC_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${TUIC_STATE_DIR}
ExecStart=${TUIC_BIN} -c ${TUIC_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$TUIC_SERVICE"
fi

systemctl daemon-reload
systemctl enable --now "$TUIC_SERVICE_NAME" >/dev/null 2>&1 || systemctl restart "$TUIC_SERVICE_NAME"

echo
ver="$("$TUIC_BIN" -V 2>/dev/null || "$TUIC_BIN" --version 2>/dev/null || true)"
echo "tuic-server installed version: ${ver:-unknown}"
