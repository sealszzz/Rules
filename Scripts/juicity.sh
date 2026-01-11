#!/usr/bin/env bash
set -euo pipefail

: "${J_PORT:=4443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

J_USER="juicity"
J_GROUP="juicity"

J_STATE_DIR="/var/lib/juicity"
J_ETC_DIR="/etc/juicity"
J_CONF="${J_ETC_DIR}/server.json"

J_BIN="/usr/local/bin/juicity"
J_SVC="/etc/systemd/system/juicity.service"

export DEBIAN_FRONTEND=noninteractive

# ---- deps ----
apt-get update >/dev/null
apt-get install -y --no-install-recommends \
  curl ca-certificates unzip openssl uuid-runtime iproute2 >/dev/null

[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

# ---- user / dir ----
getent group "$J_GROUP" >/dev/null || groupadd --system "$J_GROUP"
id -u "$J_USER" >/dev/null 2>&1 || \
  useradd --system -g "$J_GROUP" -M -d "$J_STATE_DIR" -s /usr/sbin/nologin "$J_USER"

install -d -o "$J_USER" -g "$J_GROUP" -m 750 "$J_STATE_DIR"
install -d -o root      -g "$J_GROUP" -m 750 "$J_ETC_DIR"

# ---- latest tag via 302 ----
get_latest_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
    https://github.com/juicity/juicity/releases/latest)" || return 1
  printf '%s\n' "${u##*/}"
}

TAG="$(get_latest_tag)" || { echo "Failed to resolve latest tag"; exit 1; }

case "$(uname -m)" in
  x86_64|amd64)  ARCH="x86_64" ;;
  aarch64|arm64) ARCH="arm64"  ;;
  *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

ASSET="juicity-linux-${ARCH}.zip"
URL="https://github.com/juicity/juicity/releases/download/${TAG}/${ASSET}"

# ---- download & install (server only) ----
tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

curl -fL --retry 3 --retry-delay 1 -o "${tmpd}/${ASSET}" "$URL"
unzip -q "${tmpd}/${ASSET}" -d "$tmpd"

[ -f "${tmpd}/juicity-server" ] || { echo "FATAL: juicity-server not found"; exit 1; }

install -m 0755 "${tmpd}/juicity-server" /usr/local/bin/juicity

# ---- first-time config only ----
if [ ! -f "$J_CONF" ]; then
  J_UUID="$(uuidgen)"
  J_PASS="$(openssl rand -hex 16)"

  cat >"$J_CONF" <<EOF
{
  "listen": "[::]:${J_PORT}",
  "users": {
    "${J_UUID}": "${J_PASS}"
  },
  "certificate": "${CERT}",
  "private_key": "${KEY}",
  "congestion_control": "bbr",
  "disable_outbound_udp443": true,
  "log_level": "warn"
}
EOF

  chown root:"$J_GROUP" "$J_CONF"
  chmod 640 "$J_CONF"

  echo "JUICITY UUID: ${J_UUID}"
  echo "JUICITY PASS: ${J_PASS}"
fi

# ---- systemd unit (create once) ----
if [ ! -f "$J_SVC" ]; then
  cat >"$J_SVC" <<EOF
[Unit]
Description=Juicity Server
Documentation=https://github.com/juicity/juicity
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${J_USER}
Group=${J_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${J_STATE_DIR}
ExecStart=/usr/local/bin/juicity run -c ${J_CONF} --disable-timestamp
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$J_SVC"
fi

# ---- start / reload ----
systemctl daemon-reload
if systemctl is-enabled juicity >/dev/null 2>&1; then
  systemctl try-reload-or-restart juicity || systemctl restart juicity
else
  systemctl enable --now juicity || true
fi

/usr/local/bin/juicity --version 2>/dev/null || true
