#!/usr/bin/env bash
set -euo pipefail

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${PASS:=cdaac67c6610f9d34a9fa8a5caaf56ff}"
: "${LISTEN:=[::]:443}"
: "${FALLBACK_ADDR:=[::1]:80}"
: "${LOG_LEVEL:=info}"
: "${IP_PREFERENCE:=ipv4}"
: "${CONNECT_RACE_WIDTH:=2}"
: "${HAPPY_EYEBALLS_DELAY_MS:=200}"
: "${TCP_KEEPALIVE_SEC:=30}"

ANYTLS_USER="anytls-rs"
ANYTLS_GROUP="anytls-rs"
ANYTLS_STATE_DIR="/var/lib/anytls-rs"
ANYTLS_CONF_DIR="/etc/anytls-rs"
ANYTLS_CONF_FILE="${ANYTLS_CONF_DIR}/config.json"
ANYTLS_BIN="/usr/local/bin/anytls-rs"
ANYTLS_SERVICE_NAME="anytls-rs"
ANYTLS_SERVICE="/etc/systemd/system/${ANYTLS_SERVICE_NAME}.service"
ANYTLS_REPO="sealszzz/Rules"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates tar xz-utils openssl iproute2 jq

[ -r "$CERT" ] || { echo "FATAL: missing $CERT" >&2; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY"  >&2; exit 1; }

getent group "$ANYTLS_GROUP" >/dev/null || groupadd --system "$ANYTLS_GROUP"
id -u "$ANYTLS_USER" >/dev/null 2>&1 || useradd --system -g "$ANYTLS_GROUP" -M -d "$ANYTLS_STATE_DIR" -s /usr/sbin/nologin "$ANYTLS_USER"

install -d -o "$ANYTLS_USER" -g "$ANYTLS_GROUP" -m 750 "$ANYTLS_STATE_DIR"
install -d -o root -g "$ANYTLS_GROUP" -m 750 "$ANYTLS_CONF_DIR"

get_anytls_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${ANYTLS_REPO}/releases/latest")" || return 1
  printf '%s\n' "${u##*/}"
}

install_anytls_release() {
  local ASSET BASE tmpd bin
  ANYTLS_TAG="${ANYTLS_TAG:-}"
  [ -n "$ANYTLS_TAG" ] || ANYTLS_TAG="$(get_anytls_tag 2>/dev/null || true)"
  [ -n "$ANYTLS_TAG" ] || { echo "FATAL: cannot detect anytls-rs tag" >&2; exit 1; }

  case "$(uname -m)" in
    x86_64|amd64)  ASSET="anytls-rs-linux-amd64-${ANYTLS_TAG}.tar.gz" ;;
    aarch64|arm64) ASSET="anytls-rs-linux-arm64-${ANYTLS_TAG}.tar.gz" ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac

  BASE="https://github.com/${ANYTLS_REPO}/releases/download/${ANYTLS_TAG}"
  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' RETURN

  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.tgz" "${BASE}/${ASSET}"
  mkdir -p "$tmpd/unpack"
  tar -xzf "$tmpd/pkg.tgz" -C "$tmpd/unpack"

  bin="$(find "$tmpd/unpack" -type f -name anytls-rs -perm -u+x | head -n1 || true)"
  [ -n "$bin" ] || { echo "FATAL: anytls-rs binary not found" >&2; exit 1; }

  install -m 0755 "$bin" "$ANYTLS_BIN"
  trap - RETURN
}

install_anytls_release

command -v "$ANYTLS_BIN" >/dev/null 2>&1 || { echo "FATAL: ${ANYTLS_BIN} not found" >&2; exit 1; }

if [ ! -f "$ANYTLS_CONF_FILE" ]; then
  cat >"$ANYTLS_CONF_FILE" <<EOF
{
  "log": {
    "level": "${LOG_LEVEL}"
  },
  "listen": "${LISTEN}",
  "users": {
    "anytls": "${PASS}"
  },
  "tls": {
    "certificate": "${CERT}",
    "private_key": "${KEY}"
  },
  "padding": {
    "scheme": ""
  },
  "fallback": {
    "address": "${FALLBACK_ADDR}"
  },
  "proxy_protocol": false,
  "outbound": {
    "ip_preference": "${IP_PREFERENCE}",
    "connect_race_width": ${CONNECT_RACE_WIDTH},
    "happy_eyeballs_delay_ms": ${HAPPY_EYEBALLS_DELAY_MS}
  },
  "limits": {
    "inbound_tcp_keepalive_secs": ${TCP_KEEPALIVE_SEC},
    "outbound_tcp_keepalive_secs": ${TCP_KEEPALIVE_SEC}
  }
}
EOF

  jq empty "$ANYTLS_CONF_FILE" >/dev/null 2>&1 || { echo "FATAL: invalid json generated" >&2; cat "$ANYTLS_CONF_FILE" >&2; exit 1; }

  chown root:"$ANYTLS_GROUP" "$ANYTLS_CONF_FILE"
  chmod 640 "$ANYTLS_CONF_FILE"
fi

if [ ! -f "$ANYTLS_SERVICE" ]; then
  cat >"$ANYTLS_SERVICE" <<EOF
[Unit]
Description=AnyTLS Rust Server
Documentation=https://github.com/sealszzz/Rules/releases
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${ANYTLS_USER}
Group=${ANYTLS_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${ANYTLS_STATE_DIR}
ExecStart=${ANYTLS_BIN} ${ANYTLS_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$ANYTLS_SERVICE"
fi

systemctl daemon-reload
if systemctl is-enabled --quiet "$ANYTLS_SERVICE_NAME"; then
  systemctl restart "$ANYTLS_SERVICE_NAME"
else
  systemctl enable --now "$ANYTLS_SERVICE_NAME"
fi

BIN_VER="$("$ANYTLS_BIN" --version 2>/dev/null || true)"

SHOW_PASS="${PASS:-}"
if [ -z "$SHOW_PASS" ] && [ -f "$ANYTLS_CONF_FILE" ]; then
  SHOW_PASS="$(jq -r '.users.anytls // empty' "$ANYTLS_CONF_FILE" 2>/dev/null || true)"
fi

echo "anytls-rs tag: ${ANYTLS_TAG:-unknown}"
echo "anytls-rs bin: ${BIN_VER:-unknown}"
echo "config file: ${ANYTLS_CONF_FILE}"
echo "password: ${SHOW_PASS:-unknown}"
