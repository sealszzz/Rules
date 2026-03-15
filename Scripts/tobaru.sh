#!/usr/bin/env bash
set -euo pipefail

: "${TOBARU_USER:=tobaru}"
: "${TOBARU_GROUP:=tobaru}"
: "${TOBARU_BIN:=/usr/local/bin/tobaru}"
: "${TOBARU_CONF_DIR:=/etc/tobaru}"
: "${TOBARU_CONF:=/etc/tobaru/config.toml}"
: "${TOBARU_SERVICE:=/etc/systemd/system/tobaru.service}"
: "${TOBARU_REPO:=sealszzz/Rules}"
: "${SERVICE_NAME:=tobaru}"
: "${TOBARU_LOG_DIR:=/var/log/tobaru}"

export DEBIAN_FRONTEND=noninteractive
[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root"; exit 1; }

apt-get update -qq
apt-get install -y --no-install-recommends \
  curl \
  ca-certificates \
  tar >/dev/null

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
  amd64|x86_64) ASSET_ARCH="linux-amd64" ;;
  arm64|aarch64) ASSET_ARCH="linux-arm64" ;;
  *) echo "FATAL: unsupported arch"; exit 1 ;;
esac

LATEST_URL="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${TOBARU_REPO}/releases/latest")"
TAG="${LATEST_URL##*/}"
[ -n "$TAG" ] || { echo "FATAL: failed to get latest tag"; exit 1; }

ASSET="tobaru-${ASSET_ARCH}-${TAG}.tar.gz"
URL="https://github.com/${TOBARU_REPO}/releases/download/${TAG}/${ASSET}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading: $URL"
curl -fL --retry 3 --retry-delay 1 -o "$TMP/$ASSET" "$URL"
tar -xzf "$TMP/$ASSET" -C "$TMP"

if [ -f "$TMP/tobaru" ]; then
  FOUND_BIN="$TMP/tobaru"
else
  FOUND_BIN="$(find "$TMP" -maxdepth 3 -type f -name 'tobaru' | head -n1 || true)"
fi
[ -n "${FOUND_BIN:-}" ] || { echo "FATAL: missing tobaru binary in tar"; exit 1; }

getent group "$TOBARU_GROUP" >/dev/null || groupadd --system "$TOBARU_GROUP"
id -u "$TOBARU_USER" >/dev/null 2>&1 || useradd --system --no-create-home --gid "$TOBARU_GROUP" --shell /usr/sbin/nologin "$TOBARU_USER"

install -m 0755 "$FOUND_BIN" "$TOBARU_BIN"

install -d -o root -g "$TOBARU_GROUP" -m 0750 "$TOBARU_CONF_DIR"
install -d -o "$TOBARU_USER" -g "$TOBARU_GROUP" -m 0755 "$TOBARU_LOG_DIR"

if [ ! -f "$TOBARU_CONF" ]; then
cat >"$TOBARU_CONF" <<'EOF'
[system]
worker_threads = 4
tcp_peek_timeout_ms = 500
max_udp_sessions_per_worker = 25000
udp_session_idle_timeout_sec = 60
udp_prune_interval_sec = 10

[logging]
level = "info"

[logging.flow]
enabled = true
level = "info"

[logging.stats]
enabled = true
level = "warn"

[server]
listen = "[::]:443"

[tcp]
http_honeypot = "redirect308"
ssh_backend = "blackhole"
tcp_fallback = "[::1]:9009"

[tcp.tls_routes]
"example.com" = "[::1]:9001"
"www.example.com" = "[::1]:9002"
"*.example.com" = "[::1]:9999"
tls_fallback = "blackhole"

[udp]
udp_fallback = "[::1]:9009"

[udp.quic_routes]
"example.com" = "[::1]:9001"
"www.example.com" = "[::1]:9002"
"*.example.com" = "[::1]:9999"
quic_fallback = "blackhole"
EOF
fi

chown -R root:"$TOBARU_GROUP" "$TOBARU_CONF_DIR"
chmod 0750 "$TOBARU_CONF_DIR"
chmod 0640 "$TOBARU_CONF" || true

cat >"$TOBARU_SERVICE" <<EOF
[Unit]
Description=tobaru TLS/QUIC router
After=network-online.target
Wants=network-online.target

[Service]
User=${TOBARU_USER}
Group=${TOBARU_GROUP}
Type=simple
WorkingDirectory=${TOBARU_CONF_DIR}
ExecStart=${TOBARU_BIN}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$TOBARU_SERVICE"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl restart "$SERVICE_NAME"

echo
echo "tobaru installed: $TAG"
echo "Binary : $TOBARU_BIN"
echo "Config : $TOBARU_CONF"
echo "Logs   : $TOBARU_LOG_DIR"
echo "Status : systemctl status $SERVICE_NAME --no-pager"
