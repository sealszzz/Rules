#!/usr/bin/env bash
set -euo pipefail

: "${UUID:=}"
: "${PASS:=}"

TUIC_NG_USER="tuic-ng"
TUIC_NG_GROUP="tuic-ng"
TUIC_NG_STATE_DIR="/var/lib/tuic-ng"
TUIC_NG_CONF_DIR="/etc/tuic-ng"
TUIC_NG_CONF_FILE="${TUIC_NG_CONF_DIR}/config.json"
TUIC_NG_BIN="/usr/local/bin/tuic-ng"
TUIC_NG_SERVICE_NAME="tuic-ng"
TUIC_NG_SERVICE="/etc/systemd/system/${TUIC_NG_SERVICE_NAME}.service"
TUIC_NG_REPO="sealszzz/Rules"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  curl ca-certificates tar xz-utils openssl iproute2 jq uuid-runtime

[ -r "$CERT" ] || { echo "FATAL: missing $CERT" >&2; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY"  >&2; exit 1; }

getent group "$TUIC_NG_GROUP" >/dev/null || groupadd --system "$TUIC_NG_GROUP"
id -u "$TUIC_NG_USER" >/dev/null 2>&1 || useradd --system -g "$TUIC_NG_GROUP" -M -d "$TUIC_NG_STATE_DIR" -s /usr/sbin/nologin "$TUIC_NG_USER"

install -d -o "$TUIC_NG_USER" -g "$TUIC_NG_GROUP" -m 750 "$TUIC_NG_STATE_DIR"
install -d -o root -g "$TUIC_NG_GROUP" -m 750 "$TUIC_NG_CONF_DIR"

get_tuic_ng_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${TUIC_NG_REPO}/releases/latest")" || return 1
  printf '%s\n' "${u##*/}"
}

install_tuic_ng_release() {
  local ASSET BASE tmpd bin
  TUIC_NG_TAG="${TUIC_NG_TAG:-}"
  [ -n "$TUIC_NG_TAG" ] || TUIC_NG_TAG="$(get_tuic_ng_tag 2>/dev/null || true)"
  [ -n "$TUIC_NG_TAG" ] || { echo "FATAL: cannot detect tuic-ng tag" >&2; exit 1; }

  case "$(uname -m)" in
    x86_64|amd64)  ASSET="tuic-ng-linux-amd64-${TUIC_NG_TAG}.tar.gz" ;;
    aarch64|arm64) ASSET="tuic-ng-linux-arm64-${TUIC_NG_TAG}.tar.gz" ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac

  BASE="https://github.com/${TUIC_NG_REPO}/releases/download/${TUIC_NG_TAG}"
  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' RETURN

  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.tgz" "${BASE}/${ASSET}"
  mkdir -p "$tmpd/unpack"
  tar -xzf "$tmpd/pkg.tgz" -C "$tmpd/unpack"

  bin="$(find "$tmpd/unpack" -type f -name tuic-ng -perm -u+x | head -n1 || true)"
  [ -n "$bin" ] || { echo "FATAL: tuic-ng binary not found" >&2; exit 1; }

  install -m 0755 "$bin" "$TUIC_NG_BIN"
  trap - RETURN
}

install_tuic_ng_release

command -v "$TUIC_NG_BIN" >/dev/null 2>&1 || { echo "FATAL: ${TUIC_NG_BIN} not found" >&2; exit 1; }

gen_pass() {
  openssl rand -hex 16
}

gen_uuid() {
  uuidgen
}

normalize_bool() {
  case "${1,,}" in
    1|true|yes|on)  printf 'true\n' ;;
    0|false|no|off) printf 'false\n' ;;
    *) echo "FATAL: invalid boolean: $1" >&2; exit 1 ;;
  esac
}

if [ ! -f "$TUIC_NG_CONF_FILE" ]; then
  [ -n "$UUID" ] || UUID="$(gen_uuid)"
  [ -n "$PASS" ] || PASS="$(gen_pass)"

  cat >"$TUIC_NG_CONF_FILE" <<EOF
{
  "listen": "[::]:443",
  "zero_rtt_mode": "full",
  "cert": "/etc/tls/cert.pem",
  "key": "/etc/tls/key.pem",
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
  "ip_preference": "ipv4",
  "log_level": "info",
  "max_idle_secs": 200,
  "keepalive_secs": 20
}
EOF

  jq empty "$TUIC_NG_CONF_FILE" >/dev/null 2>&1 || {
    echo "FATAL: invalid json generated" >&2
    cat "$TUIC_NG_CONF_FILE" >&2
    exit 1
  }

  chown root:"$TUIC_NG_GROUP" "$TUIC_NG_CONF_FILE"
  chmod 640 "$TUIC_NG_CONF_FILE"
fi

if [ ! -f "$TUIC_NG_SERVICE" ]; then
  cat >"$TUIC_NG_SERVICE" <<EOF
[Unit]
Description=TUIC-NG Server
Documentation=https://github.com/sealszzz/Rules/releases
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${TUIC_NG_USER}
Group=${TUIC_NG_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${TUIC_NG_STATE_DIR}
ExecStart=${TUIC_NG_BIN} ${TUIC_NG_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$TUIC_NG_SERVICE"
fi

systemctl daemon-reload
if systemctl is-enabled --quiet "$TUIC_NG_SERVICE_NAME"; then
  systemctl restart "$TUIC_NG_SERVICE_NAME"
else
  systemctl enable --now "$TUIC_NG_SERVICE_NAME"
fi

BIN_VER="$("$TUIC_NG_BIN" --version 2>/dev/null | head -n1 || true)"

SHOW_UUID="${UUID:-}"
SHOW_PASS="${PASS:-}"
if [ -f "$TUIC_NG_CONF_FILE" ]; then
  [ -n "$SHOW_UUID" ] || SHOW_UUID="$(jq -r '.users[0].uuid // empty' "$TUIC_NG_CONF_FILE" 2>/dev/null || true)"
  [ -n "$SHOW_PASS" ] || SHOW_PASS="$(jq -r '.users[0].password // empty' "$TUIC_NG_CONF_FILE" 2>/dev/null || true)"
fi

echo "tuic-ng tag: ${TUIC_NG_TAG:-unknown}"
echo "tuic-ng bin: ${BIN_VER:-unknown}"
echo "config file: ${TUIC_NG_CONF_FILE}"
echo "uuid: ${SHOW_UUID:-unknown}"
echo "password: ${SHOW_PASS:-unknown}"
