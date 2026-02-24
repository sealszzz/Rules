#!/usr/bin/env bash
set -euo pipefail

: "${TOBARU_USER:=tobaru}"
: "${TOBARU_GROUP:=tobaru}"
: "${TOBARU_BIN:=/usr/local/bin/tobaru}"
: "${TOBARU_CONF_DIR:=/etc/tobaru}"
: "${TOBARU_CONF:=/etc/tobaru/tobaru.yml}"
: "${TOBARU_SERVICE:=/etc/systemd/system/tobaru.service}"
: "${TOBARU_REPO:=sealszzz/Tobaru}"
: "${SERVICE_NAME:=tobaru}"

export DEBIAN_FRONTEND=noninteractive
[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root"; exit 1; }

apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates tar >/dev/null

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
  amd64|x86_64) ASSET_ARCH="x86_64" ;;
  arm64|aarch64) ASSET_ARCH="aarch64" ;;
  *) echo "FATAL: unsupported arch"; exit 1 ;;
esac

LATEST_URL="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${TOBARU_REPO}/releases/latest")"
TAG="${LATEST_URL##*/}"
[ -n "$TAG" ] || { echo "FATAL: failed to get latest tag"; exit 1; }

ASSET="tobaru-${ASSET_ARCH}-unknown-linux-gnu-${TAG}.tar.gz"
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

install -m 0755 "$FOUND_BIN" "$TOBARU_BIN"

getent group "$TOBARU_GROUP" >/dev/null || groupadd --system "$TOBARU_GROUP"
id -u "$TOBARU_USER" >/dev/null 2>&1 || useradd --system --no-create-home --gid "$TOBARU_GROUP" --shell /usr/sbin/nologin "$TOBARU_USER"

install -d -o root -g "$TOBARU_GROUP" -m 0750 "$TOBARU_CONF_DIR"

if [ ! -f "$TOBARU_CONF" ]; then
cat >"$TOBARU_CONF" <<'EOF'
- address: "[::]:443"
  transport: tcp
  targets:
    - location: 127.0.0.1:1
      allowlist: 0.0.0.0/0
      server_tls:
        mode: passthrough
        sni_hostnames:
          - none
          - any

    - location: 127.0.0.1:9001
      allowlist: 0.0.0.0/0
      server_tls:
        mode: passthrough
        sni_hostnames: "example.com"

    - location: 127.0.0.1:9002
      allowlist: 0.0.0.0/0
      server_tls:
        mode: passthrough
        sni_hostnames: "www.example.com"

    - location: 127.0.0.1:9003
      allowlist: 0.0.0.0/0
      server_tls:
        mode: passthrough
        sni_hostnames: "global.example.com"

    - location: 127.0.0.1:9999
      allowlist: 0.0.0.0/0
      server_tls:
        mode: passthrough
        sni_hostnames: "*.example.com"

    - location: 127.0.0.1:9009
      allowlist: 0.0.0.0/0

- address: "[::]:443"
  transport: udp
  target:
    - location: 127.0.0.1:9009
      allowlist: 0.0.0.0/0
EOF
fi

chown -R root:"$TOBARU_GROUP" "$TOBARU_CONF_DIR"
chmod 0750 "$TOBARU_CONF_DIR"
chmod 0640 "$TOBARU_CONF" || true

cat >"$TOBARU_SERVICE" <<EOF
[Unit]
Description=tobaru TLS SNI passthrough router
After=network-online.target
Wants=network-online.target

[Service]
User=${TOBARU_USER}
Group=${TOBARU_GROUP}
Type=simple
ExecStart=${TOBARU_BIN} ${TOBARU_CONF}
Environment="RUST_LOG=warn,tobaru=info"
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
systemctl restart "$SERVICE_NAME"

echo
echo "tobaru installed: $TAG"
echo "Binary : $TOBARU_BIN"
echo "Config : $TOBARU_CONF"
echo "Status : systemctl status $SERVICE_NAME --no-pager"
