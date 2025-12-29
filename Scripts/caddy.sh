#!/usr/bin/env bash
set -euo pipefail

: "${ANYTLS_PORT:=8001}"
: "${VLESS_PORT:=8002}"
: "${ANYTLS_SNI:=anytls.example.com}"

: "${TUIC_PORT:=9001}"
: "${JUICITY_PORT:=9002}"
: "${TUIC_SNI:=tuic.example.com}"
: "${JUICITY_SNI:=juicity.example.com}"

: "${CADDY_USER:=caddy}"
: "${CADDY_GROUP:=caddy}"
: "${CADDY_BIN:=/usr/local/bin/caddy-l4}"
: "${CADDY_CONF:=/etc/caddy/caddy.json}"
: "${CADDY_SERVICE:=/etc/systemd/system/caddy-l4.service}"
: "${CADDY_REPO:=sealszzz/Caddy}"

SERVICE_NAME="caddy-l4"

export DEBIAN_FRONTEND=noninteractive
[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root"; exit 1; }

apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates tar

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
  amd64|x86_64) ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "FATAL: unsupported arch"; exit 1 ;;
esac

LATEST_URL="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
  "https://github.com/${CADDY_REPO}/releases/latest")"
TAG="${LATEST_URL##*/}"
[ -n "$TAG" ] || { echo "FATAL: failed to get tag"; exit 1; }

ASSET="caddy-l4-linux-${ARCH}-${TAG}.tar.gz"
URL="https://github.com/${CADDY_REPO}/releases/download/${TAG}/${ASSET}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fL "$URL" -o "$TMP/$ASSET"
tar -xzf "$TMP/$ASSET" -C "$TMP"
install -m 0755 "$TMP/caddy-l4-linux-${ARCH}" "$CADDY_BIN"

getent group "$CADDY_GROUP" >/dev/null || groupadd --system "$CADDY_GROUP"
id -u "$CADDY_USER" >/dev/null 2>&1 || \
  useradd --system --no-create-home --gid "$CADDY_GROUP" \
  --shell /usr/sbin/nologin "$CADDY_USER"

install -d -o root -g "$CADDY_GROUP" -m 0750 /etc/caddy

if [ ! -f "$CADDY_CONF" ]; then
cat >"$CADDY_CONF" <<EOF
{
  "admin": { "disabled": true },
  "apps": {
    "layer4": {
      "servers": {
        "tcp443": {
          "listen": [":443"],
          "routes": [
            {
              "match": [{ "tls": { "sni": ["${ANYTLS_SNI}"] } }],
              "handle": [{
                "handler": "proxy",
                "upstreams": [{ "dial": ["tcp/127.0.0.1:${ANYTLS_PORT}"] }]
              }]
            },
            {
              "match": [{ "tls": {} }],
              "handle": [{
                "handler": "proxy",
                "upstreams": [{ "dial": ["tcp/127.0.0.1:${VLESS_PORT}"] }]
              }]
            }
          ]
        },
        "udp443": {
          "listen": ["udp/:443"],
          "routes": [
            {
              "match": [{ "quic": { "sni": ["${TUIC_SNI}"] } }],
              "handle": [{
                "handler": "proxy",
                "upstreams": [{ "dial": ["udp/127.0.0.1:${TUIC_PORT}"] }]
              }]
            },
            {
              "match": [{ "quic": { "sni": ["${JUICITY_SNI}"] } }],
              "handle": [{
                "handler": "proxy",
                "upstreams": [{ "dial": ["udp/127.0.0.1:${JUICITY_PORT}"] }]
              }]
            }
          ]
        }
      }
    }
  }
}
EOF
fi

chown root:"$CADDY_GROUP" "$CADDY_CONF"
chmod 0640 "$CADDY_CONF"

cat >"$CADDY_SERVICE" <<EOF
[Unit]
Description=Caddy layer4 TCP+UDP 443 SNI proxy
After=network.target

[Service]
User=${CADDY_USER}
Group=${CADDY_GROUP}

StateDirectory=caddy
Environment=HOME=/var/lib/caddy
Environment=XDG_CONFIG_HOME=/var/lib/caddy/.config

ExecStart=${CADDY_BIN} run --config ${CADDY_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144

Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$CADDY_SERVICE"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl restart "$SERVICE_NAME"

echo "caddy-l4 installed: $TAG"
