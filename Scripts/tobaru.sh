#!/usr/bin/env bash
set -euo pipefail

: "${TOBARU_USER:=tobaru}"
: "${TOBARU_GROUP:=tobaru}"
: "${TOBARU_BIN:=/usr/local/bin/tobaru}"
: "${TOBARU_CONF_DIR:=/etc/tobaru}"
: "${TOBARU_CONF:=/etc/tobaru/tobaru.yml}"
: "${TOBARU_SERVICE:=/etc/systemd/system/tobaru.service}"
: "${TOBARU_REPO:=sealszzz/Rules}"
: "${SERVICE_NAME:=tobaru}"
: "${TOBARU_TAG:=}"

export DEBIAN_FRONTEND=noninteractive
[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root"; exit 1; }

apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates tar jq >/dev/null

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
  amd64|x86_64) ASSET_ARCH="linux-amd64" ;;
  arm64|aarch64) ASSET_ARCH="linux-arm64" ;;
  *) echo "FATAL: unsupported arch"; exit 1 ;;
esac

if [ -z "$TOBARU_TAG" ]; then
  API="https://api.github.com/repos/${TOBARU_REPO}/releases?per_page=50"
  TOBARU_TAG="$(curl -fsSL "$API" | jq -r --arg asset "tobaru-${ASSET_ARCH}-" '
    map(select(any(.assets[]?; (.name | startswith($asset) and endswith(".tar.gz")))))
    | .[0].tag_name // empty
  ')"
fi

[ -n "$TOBARU_TAG" ] || { echo "FATAL: failed to find a tobaru release for ${ASSET_ARCH}"; exit 1; }

ASSET="tobaru-${ASSET_ARCH}-${TOBARU_TAG}.tar.gz"
URL="https://github.com/${TOBARU_REPO}/releases/download/${TOBARU_TAG}/${ASSET}"

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

install -m 0755 "$FOUND_BIN" "$TOBARU_BIN"

getent group "$TOBARU_GROUP" >/dev/null || groupadd --system "$TOBARU_GROUP"
id -u "$TOBARU_USER" >/dev/null 2>&1 || useradd --system --no-create-home --gid "$TOBARU_GROUP" --shell /usr/sbin/nologin "$TOBARU_USER"

install -d -o root -g "$TOBARU_GROUP" -m 0750 "$TOBARU_CONF_DIR"

if [ ! -f "$TOBARU_CONF" ]; then
cat >"$TOBARU_CONF" <<'EOF'
logging:
  level: info

listeners:
  - address: "[::]:443"
    transport: tcp
    targets:
      - location: drop
        server_tls:
          sni_hostnames: [none, any]

      - location: "[::1]:9001"
        server_tls:
          sni_hostnames:
            - example.com
        proxy_protocol: v2

      - location: "[::1]:9002"
        server_tls:
          sni_hostnames:
            - www.example.com
        proxy_protocol: v2

      - location: "[::1]:9999"
        server_tls:
          sni_hostnames:
            - "*.example.com"
        proxy_protocol: v2

      - location: "[::1]:9009"

  - address: "[::]:443"
    transport: udp
    targets:
      - location: drop
        server_quic:
          sni_hostnames: [none, any]

      - location: "[::1]:9001"
        server_quic:
          sni_hostnames:
            - example.com

      - location: "[::1]:9002"
        server_quic:
          sni_hostnames:
            - www.example.com

      - location: "[::1]:9999"
        server_quic:
          sni_hostnames:
            - "*.example.com"

      - location: "[::1]:9009"
EOF
fi

chown -R root:"$TOBARU_GROUP" "$TOBARU_CONF_DIR"
chmod 0750 "$TOBARU_CONF_DIR"
chmod 0640 "$TOBARU_CONF" || true

cat >"$TOBARU_SERVICE" <<EOF
[Unit]
Description=tobaru TLS/QUIC SNI router
After=network-online.target
Wants=network-online.target

[Service]
User=${TOBARU_USER}
Group=${TOBARU_GROUP}
Type=simple
ExecStart=${TOBARU_BIN} ${TOBARU_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=2s
SyslogIdentifier=tobaru
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$TOBARU_SERVICE"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl restart "$SERVICE_NAME"

echo
echo "tobaru installed: $TOBARU_TAG"
echo "Binary : $TOBARU_BIN"
echo "Config  : $TOBARU_CONF"
systemctl --no-pager --full status "$SERVICE_NAME" || true

reboot
