#!/usr/bin/env bash
# tuic-min: no-API latest tag, glibc only (x86_64/aarch64), plain binary install
set -euo pipefail

: "${TUIC_PORT:=8443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

TUIC_USER="tuic"
TUIC_GROUP="tuic"

TUIC_STATE_DIR="/var/lib/tuic"
TUIC_CONF_DIR="/etc/tuic"
TUIC_CONF_FILE="${TUIC_CONF_DIR}/config.toml"

TUIC_BIN="/usr/local/bin/tuic-server"
TUIC_SERVICE_NAME="tuic-server"
TUIC_SERVICE="/etc/systemd/system/${TUIC_SERVICE_NAME}.service"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates uuid-runtime openssl iproute2

[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

getent group "$TUIC_GROUP" >/dev/null || groupadd --system "$TUIC_GROUP"
id -u "$TUIC_USER" >/dev/null 2>&1 || \
  useradd --system -g "$TUIC_GROUP" -M -d "$TUIC_STATE_DIR" -s /usr/sbin/nologin "$TUIC_USER"

install -d -o "$TUIC_USER" -g "$TUIC_GROUP" -m 750 "$TUIC_STATE_DIR"
install -d -o root        -g "$TUIC_GROUP" -m 750 "$TUIC_CONF_DIR"

get_latest_tag() {
  local final
  final="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
           https://github.com/Itsusinn/tuic/releases/latest)" || return 1
  printf '%s\n' "${final##*/}"
}

echo "[*] Query latest TUIC release (no-API)…"
tag="$(get_latest_tag)" || { echo "Failed to resolve latest tag"; exit 1; }

case "$(uname -m)" in
  x86_64|amd64)  ARK="x86_64"  ;;
  aarch64|arm64) ARK="aarch64" ;;
  *) echo "Unsupported arch: $(uname -m) (x86_64/aarch64 only)" >&2; exit 1 ;;
esac

asset_name="tuic-server-${ARK}-linux"
dl_url="https://github.com/Itsusinn/tuic/releases/download/${tag}/${asset_name}"

echo "[*] Install version: ${tag}"
echo "[*] Asset:           ${asset_name}"

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
bin_dl="${tmpd}/${asset_name}"

curl -fL --retry 3 --retry-delay 1 -o "$bin_dl" "$dl_url"
chmod +x "$bin_dl"
install -m 0755 "$bin_dl" "$TUIC_BIN"

if [ ! -f "$TUIC_CONF_FILE" ]; then
  TUIC_UUID="${TUIC_UUID:-$(uuidgen)}"
  TUIC_PASS="${TUIC_PASS:-$(openssl rand -hex 16)}"

  cat >"$TUIC_CONF_FILE" <<EOF
log_level = "warn"
server = "[::]:${TUIC_PORT}"
udp_relay_ipv6 = true
zero_rtt_handshake = false
dual_stack = false

[users]
"${TUIC_UUID}" = "${TUIC_PASS}"

[tls]
certificate = "${CERT}"
private_key = "${KEY}"
alpn = ["h3"]

[quic.congestion_control]
controller = "bbr"

[outbound.default]
type = "direct"
ip_mode = "v4first"
EOF

  chown root:"$TUIC_GROUP" "$TUIC_CONF_FILE"
  chmod 640 "$TUIC_CONF_FILE"
  echo "TUIC UUID: ${TUIC_UUID}"
  echo "TUIC PASS: ${TUIC_PASS}"
fi

if [ ! -f "$TUIC_SERVICE" ]; then
  cat >"$TUIC_SERVICE" <<EOF
[Unit]
Description=TUIC Server (Itsusinn)
Documentation=https://github.com/Itsusinn/tuic
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${TUIC_USER}
Group=${TUIC_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${TUIC_STATE_DIR}
ExecStart=${TUIC_BIN} -d ${TUIC_CONF_DIR}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
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
if systemctl is-enabled "$TUIC_SERVICE_NAME" >/dev/null 2>&1; then
  systemctl try-reload-or-restart "$TUIC_SERVICE_NAME" || systemctl restart "$TUIC_SERVICE_NAME"
else
  systemctl enable --now "$TUIC_SERVICE_NAME" || true
fi

echo
"$TUIC_BIN" -V 2>/dev/null || "$TUIC_BIN" --version 2>/dev/null || true
