#!/usr/bin/env bash
set -euo pipefail

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${PASS:=}"
: "${ANYTLS_TAG:=}"

APP_USER="anytls-rs"
APP_GROUP="anytls-rs"
APP_STATE_DIR="/var/lib/anytls-rs"
APP_CONF_DIR="/etc/anytls-rs"
APP_CONF_FILE="${APP_CONF_DIR}/config.json"
APP_BIN="/usr/local/bin/anytls-rs"
APP_SERVICE_NAME="anytls-rs"
APP_SERVICE="/etc/systemd/system/${APP_SERVICE_NAME}.service"
APP_REPO="sealszzz/Rules"
APP_ASSET_BASENAME="anytls-rs"
APP_BIN_NAME="anytls-rs"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates tar xz-utils openssl jq

[ -r "$CERT" ] || { echo "FATAL: missing $CERT" >&2; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY" >&2; exit 1; }

getent group "$APP_GROUP" >/dev/null || groupadd --system "$APP_GROUP"
id -u "$APP_USER" >/dev/null 2>&1 || useradd --system -g "$APP_GROUP" -M -d "$APP_STATE_DIR" -s /usr/sbin/nologin "$APP_USER"

install -d -o "$APP_USER" -g "$APP_GROUP" -m 750 "$APP_STATE_DIR"
install -d -o root -g "$APP_GROUP" -m 750 "$APP_CONF_DIR"

get_release_tag() {
  local repo="$1"
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${repo}/releases/latest")" || return 1
  printf '%s\n' "${u##*/}"
}

install_release_asset() {
  local repo="$1"
  local tag="$2"
  local base_name="$3"
  local bin_name="$4"
  local tmpd asset base bin

  case "$(uname -m)" in
    x86_64|amd64)  asset="${base_name}-linux-amd64-${tag}.tar.gz" ;;
    aarch64|arm64) asset="${base_name}-linux-arm64-${tag}.tar.gz" ;;
    *) echo "FATAL: unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac

  base="https://github.com/${repo}/releases/download/${tag}"
  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' RETURN

  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.tgz" "${base}/${asset}"
  mkdir -p "$tmpd/unpack"
  tar -xzf "$tmpd/pkg.tgz" -C "$tmpd/unpack"

  bin="$(find "$tmpd/unpack" -type f -name "$bin_name" -perm -u+x | head -n1 || true)"
  [ -n "$bin" ] || { echo "FATAL: ${bin_name} binary not found" >&2; exit 1; }

  install -m 0755 "$bin" "$APP_BIN"
  trap - RETURN
}

gen_pass() {
  openssl rand -hex 16
}

[ -n "$ANYTLS_TAG" ] || ANYTLS_TAG="$(get_release_tag "$APP_REPO" 2>/dev/null || true)"
[ -n "$ANYTLS_TAG" ] || { echo "FATAL: cannot detect anytls-rs tag" >&2; exit 1; }

install_release_asset "$APP_REPO" "$ANYTLS_TAG" "$APP_ASSET_BASENAME" "$APP_BIN_NAME"

command -v "$APP_BIN" >/dev/null 2>&1 || { echo "FATAL: ${APP_BIN} not found" >&2; exit 1; }

if [ ! -f "$APP_CONF_FILE" ]; then
  [ -n "$PASS" ] || PASS="$(gen_pass)"

  cat >"$APP_CONF_FILE" <<EOF
{
  "log": {
    "level": "info"
  },
  "listen": "[::]:443",
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
    "address": "[::1]:80"
  },
  "proxy_protocol": false,
  "outbound": {
    "ip_preference": "v4v6",
    "connect_race_width": 2,
    "happy_eyeballs_delay_ms": 200
  },
  "tcp": {
    "keepalive_idle_sec": 30,
    "keepalive_interval_sec": 30
  }
}
EOF

  jq empty "$APP_CONF_FILE" >/dev/null 2>&1 || { echo "FATAL: invalid json generated" >&2; cat "$APP_CONF_FILE" >&2; exit 1; }
  chown root:"$APP_GROUP" "$APP_CONF_FILE"
  chmod 640 "$APP_CONF_FILE"
fi

if [ ! -f "$APP_SERVICE" ]; then
  cat >"$APP_SERVICE" <<EOF
[Unit]
Description=AnyTLS Rust Server
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

SHOW_PASS="${PASS:-}"
if [ -z "$SHOW_PASS" ] && [ -f "$APP_CONF_FILE" ]; then
  SHOW_PASS="$(jq -r '.users.anytls // empty' "$APP_CONF_FILE" 2>/dev/null || true)"
fi

echo "app: anytls-rs"
echo "tag: ${ANYTLS_TAG:-unknown}"
echo "bin: ${BIN_VER:-unknown}"
echo "config: ${APP_CONF_FILE}"
echo "password: ${SHOW_PASS:-unknown}"
