#!/usr/bin/env bash
set -euo pipefail

: "${TOBARU_USER:=tobaru}"
: "${TOBARU_GROUP:=tobaru}"
: "${TOBARU_BIN:=/usr/local/bin/tobaru}"
: "${TOBARU_CONF_DIR:=/etc/tobaru}"
: "${TOBARU_CONF:=/etc/tobaru/tobaru.yml}"
: "${TOBARU_SERVICE:=/etc/systemd/system/tobaru.service}"
: "${TOBARU_REPO:=cfal/tobaru}"
: "${SERVICE_NAME:=tobaru}"

export DEBIAN_FRONTEND=noninteractive
[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root"; exit 1; }

apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates tar >/dev/null

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
  amd64|x86_64) ASSET_ARCH=x86_64 ;;
  arm64|aarch64) ASSET_ARCH=aarch64 ;;
  *) echo "FATAL: unsupported arch"; exit 1 ;;
esac

LATEST_URL="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${TOBARU_REPO}/releases/latest")"
TAG="${LATEST_URL##*/}"
[ -n "$TAG" ] || { echo "FATAL: failed to get latest tag"; exit 1; }

ASSET="tobaru-${ASSET_ARCH}-unknown-linux-gnu.tar.gz"
URL="https://github.com/${TOBARU_REPO}/releases/download/${TAG}/${ASSET}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 3 --retry-delay 1 -o "$TMP/$ASSET" "$URL"
tar -xzf "$TMP/$ASSET" -C "$TMP"

# The tarball usually contains a single binary named "tobaru"
if [ -f "$TMP/tobaru" ]; then
  install -m 0755 "$TMP/tobaru" "$TOBARU_BIN"
else
  # Fallback: find it if the archive has subdirs or different paths
  FOUND_BIN="$(find "$TMP" -maxdepth 3 -type f -name 'tobaru' | head -n1 || true)"
  [ -n "${FOUND_BIN:-}" ] || { echo "FATAL: missing tobaru binary in tar"; exit 1; }
  install -m 0755 "$FOUND_BIN" "$TOBARU_BIN"
fi

getent group "$TOBARU_GROUP" >/dev/null || groupadd --system "$TOBARU_GROUP"
id -u "$TOBARU_USER" >/dev/null 2>&1 || useradd --system --no-create-home --gid "$TOBARU_GROUP" --shell /usr/sbin/nologin "$TOBARU_USER"

install -d -o root -g "$TOBARU_GROUP" -m 0750 "$TOBARU_CONF_DIR"

# Write config once (only if not exists)
if [ ! -f "$TOBARU_CONF" ]; then
cat >"$TOBARU_CONF" <<'YAML'
- address: 0.0.0.0:443
  transport: tcp
  targets:
    - location: 127.0.0.1:9001
      server_tls:
        mode: passthrough
        sni_hostnames: "example.com"

    - location: 127.0.0.1:9002
      server_tls:
        mode: passthrough
        sni_hostnames: "www.example.com"

    - location: 127.0.0.1:9003
      server_tls:
        mode: passthrough
        sni_hostnames: "global.example.com"

    - location: 127.0.0.1:9999
      server_tls:
        mode: passthrough
        sni_hostnames: any

    - location: 127.0.0.1:9009
      server_tls:
        mode: passthrough
        sni_hostnames: none
YAML
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
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

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
