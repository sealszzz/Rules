#!/usr/bin/env bash
set -euo pipefail

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${UUID:=}"
: "${PASS:=}"
: "${LISTEN_PORT:=443}"

: "${ZERO_RTT_MODE:=auth}"
: "${ALPN:=h3}"
: "${CONGESTION_CONTROL:=bbr}"
: "${IP_PREFERENCE:=v4v6}"
: "${LOG_LEVEL:=info}"

: "${MAX_IDLE_SECS:=200}"
: "${KEEPALIVE_SECS:=20}"
: "${TCP_CONNECT_TIMEOUT_SECS:=8}"
: "${DNS_CACHE_TTL_SECS:=60}"
: "${AUTH_TIMEOUT_SECS:=5}"

: "${MAX_HANDSHAKES:=64}"
: "${MAX_CONNECTIONS:=256}"
: "${MAX_UDP_ASSOCS_PER_SESSION:=16}"

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

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行" >&2
    exit 1
  fi
}

normalize_zero_rtt_mode() {
  case "$1" in
    off|auth|full) printf '%s' "$1" ;;
    *) echo "FATAL: invalid ZERO_RTT_MODE: $1 (use off/auth/full)" >&2; exit 1 ;;
  esac
}

normalize_ip_preference() {
  case "$1" in
    v4v6|v6v4|system) printf '%s' "$1" ;;
    *) echo "FATAL: invalid IP_PREFERENCE: $1 (use v4v6/v6v4/system)" >&2; exit 1 ;;
  esac
}

normalize_log_level() {
  case "$1" in
    trace|debug|info|warn|error) printf '%s' "$1" ;;
    *) echo "FATAL: invalid LOG_LEVEL: $1 (use trace/debug/info/warn/error)" >&2; exit 1 ;;
  esac
}

normalize_cc() {
  case "$1" in
    bbr|cubic|new_reno) printf '%s' "$1" ;;
    *) echo "FATAL: invalid CONGESTION_CONTROL: $1 (use bbr/cubic/new_reno)" >&2; exit 1 ;;
  esac
}

normalize_u64_gt0() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "FATAL: ${name} must be an integer" >&2; exit 1; }
  [ "$value" -gt 0 ] || { echo "FATAL: ${name} must be > 0" >&2; exit 1; }
  printf '%s' "$value"
}

need_root

apt-get update
apt-get install -y --no-install-recommends \
  curl ca-certificates tar xz-utils openssl jq uuid-runtime

[ -r "$CERT" ] || { echo "FATAL: missing $CERT" >&2; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY"  >&2; exit 1; }

ZERO_RTT_MODE="$(normalize_zero_rtt_mode "$ZERO_RTT_MODE")"
IP_PREFERENCE="$(normalize_ip_preference "$IP_PREFERENCE")"
LOG_LEVEL="$(normalize_log_level "$LOG_LEVEL")"
CONGESTION_CONTROL="$(normalize_cc "$CONGESTION_CONTROL")"
MAX_IDLE_SECS="$(normalize_u64_gt0 MAX_IDLE_SECS "$MAX_IDLE_SECS")"
KEEPALIVE_SECS="$(normalize_u64_gt0 KEEPALIVE_SECS "$KEEPALIVE_SECS")"
TCP_CONNECT_TIMEOUT_SECS="$(normalize_u64_gt0 TCP_CONNECT_TIMEOUT_SECS "$TCP_CONNECT_TIMEOUT_SECS")"
DNS_CACHE_TTL_SECS="$(normalize_u64_gt0 DNS_CACHE_TTL_SECS "$DNS_CACHE_TTL_SECS")"
AUTH_TIMEOUT_SECS="$(normalize_u64_gt0 AUTH_TIMEOUT_SECS "$AUTH_TIMEOUT_SECS")"
MAX_HANDSHAKES="$(normalize_u64_gt0 MAX_HANDSHAKES "$MAX_HANDSHAKES")"
MAX_CONNECTIONS="$(normalize_u64_gt0 MAX_CONNECTIONS "$MAX_CONNECTIONS")"
MAX_UDP_ASSOCS_PER_SESSION="$(normalize_u64_gt0 MAX_UDP_ASSOCS_PER_SESSION "$MAX_UDP_ASSOCS_PER_SESSION")"

if [ "$KEEPALIVE_SECS" -ge "$MAX_IDLE_SECS" ]; then
  echo "FATAL: KEEPALIVE_SECS must be smaller than MAX_IDLE_SECS" >&2
  exit 1
fi

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
  local asset base tmpd bin
  TUIC_NG_TAG="${TUIC_NG_TAG:-}"
  [ -n "$TUIC_NG_TAG" ] || TUIC_NG_TAG="$(get_tuic_ng_tag 2>/dev/null || true)"
  [ -n "$TUIC_NG_TAG" ] || { echo "FATAL: cannot detect tuic-ng tag" >&2; exit 1; }

  case "$(uname -m)" in
    x86_64|amd64)  asset="tuic-ng-linux-amd64-${TUIC_NG_TAG}.tar.gz" ;;
    aarch64|arm64) asset="tuic-ng-linux-arm64-${TUIC_NG_TAG}.tar.gz" ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac

  base="https://github.com/${TUIC_NG_REPO}/releases/download/${TUIC_NG_TAG}"
  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' RETURN

  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.tgz" "${base}/${asset}"
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

if [ ! -f "$TUIC_NG_CONF_FILE" ]; then
  [ -n "$UUID" ] || UUID="$(gen_uuid)"
  [ -n "$PASS" ] || PASS="$(gen_pass)"

  jq -n \
    --arg listen "[::]:${LISTEN_PORT}" \
    --arg zero_rtt_mode "$ZERO_RTT_MODE" \
    --arg cert "$CERT" \
    --arg key "$KEY" \
    --arg uuid "$UUID" \
    --arg password "$PASS" \
    --arg alpn "$ALPN" \
    --arg congestion_control "$CONGESTION_CONTROL" \
    --arg ip_preference "$IP_PREFERENCE" \
    --arg log_level "$LOG_LEVEL" \
    --argjson max_idle_secs "$MAX_IDLE_SECS" \
    --argjson keepalive_secs "$KEEPALIVE_SECS" \
    --argjson tcp_connect_timeout_secs "$TCP_CONNECT_TIMEOUT_SECS" \
    --argjson dns_cache_ttl_secs "$DNS_CACHE_TTL_SECS" \
    --argjson auth_timeout_secs "$AUTH_TIMEOUT_SECS" \
    --argjson max_handshakes "$MAX_HANDSHAKES" \
    --argjson max_connections "$MAX_CONNECTIONS" \
    --argjson max_udp_assocs_per_session "$MAX_UDP_ASSOCS_PER_SESSION" \
    '
    {
      listen: $listen,
      zero_rtt_mode: $zero_rtt_mode,
      cert: $cert,
      key: $key,
      users: [
        {
          uuid: $uuid,
          password: $password
        }
      ],
      alpn: [$alpn],
      congestion_control: $congestion_control,
      ip_preference: $ip_preference,
      log_level: $log_level,
      max_idle_secs: $max_idle_secs,
      keepalive_secs: $keepalive_secs,
      tcp_connect_timeout_secs: $tcp_connect_timeout_secs,
      dns_cache_ttl_secs: $dns_cache_ttl_secs,
      auth_timeout_secs: $auth_timeout_secs,
      max_handshakes: $max_handshakes,
      max_connections: $max_connections,
      max_udp_assocs_per_session: $max_udp_assocs_per_session
    }
    ' > "$TUIC_NG_CONF_FILE"

  chown root:"$TUIC_NG_GROUP" "$TUIC_NG_CONF_FILE"
  chmod 640 "$TUIC_NG_CONF_FILE"
fi

if [ ! -f "$TUIC_NG_SERVICE" ]; then
  cat >"$TUIC_NG_SERVICE" <<EOF2
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
EOF2
  chmod 644 "$TUIC_NG_SERVICE"
fi

systemctl daemon-reload
if systemctl is-enabled --quiet "$TUIC_NG_SERVICE_NAME"; then
  systemctl restart "$TUIC_NG_SERVICE_NAME"
else
  systemctl enable --now "$TUIC_NG_SERVICE_NAME"
fi

BIN_VER="$($TUIC_NG_BIN --version 2>/dev/null | head -n1 || true)"

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
