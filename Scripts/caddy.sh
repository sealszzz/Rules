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

CADDY_SERVICE_NAME="caddy-l4"

export DEBIAN_FRONTEND=noninteractive
[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root"; exit 1; }

apt-get update >/dev/null
apt-get install -y --no-install-recommends curl ca-certificates tar >/dev/null

detect_arch() {
  case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    amd64|x86_64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) echo "FATAL: unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac
}
ARCH="$(detect_arch)"

LATEST_URL="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
  "https://github.com/${CADDY_REPO}/releases/latest")"
TAG="${LATEST_URL##*/}"
[ -n "$TAG" ] || { echo "FATAL: failed to resolve latest tag"; exit 1; }

ASSET="caddy-l4-linux-${ARCH}-${TAG}.tar.gz"
URL="https://github.com/${CADDY_REPO}/releases/download/${TAG}/${ASSET}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fL --retry 3 --retry-delay 1 -o "$TMP_DIR/$ASSET" "$URL"
tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR"

BIN_SRC="$TMP_DIR/caddy-l4-linux-${ARCH}"
[ -f "$BIN_SRC" ] || { echo "FATAL: binary missing: $BIN_SRC"; exit 1; }
install -m 0755 "$BIN_SRC" "$CADDY_BIN"

getent group "$CADDY_GROUP" >/dev/null || groupadd --system "$CADDY_GROUP"
id -u "$CADDY_USER" >/dev/null 2>&1 || \
  useradd --system --no-create-home --gid "$CADDY_GROUP" --shell /usr/sbin/nologin "$CADDY_USER"

# /etc/caddy 必须可进入，config 必须可读（避免 permission denied）
install -d -m 0755 -o root -g "$CADDY_GROUP" /etc/caddy

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
              "match": [
                { "tls": { "sni": ["${ANYTLS_SNI}"] } }
              ],
              "handle": [
                {
                  "handler": "proxy",
                  "upstreams": [
                    { "dial": ["tcp/127.0.0.1:${ANYTLS_PORT}"] }
                  ]
                }
              ]
            },
            {
              "match": [
                { "tls": {} }
              ],
              "handle": [
                {
                  "handler": "proxy",
                  "upstreams": [
                    { "dial": ["tcp/127.0.0.1:${VLESS_PORT}"] }
                  ]
                }
              ]
            }
          ]
        },
        "udp443": {
          "listen": ["udp/:443"],
          "routes": [
            {
              "match": [
                { "quic": { "sni": ["${TUIC_SNI}"] } }
              ],
              "handle": [
                {
                  "handler": "proxy",
                  "upstreams": [
                    { "dial": ["udp/127.0.0.1:${TUIC_PORT}"] }
                  ]
                }
              ]
            },
            {
              "match": [
                { "quic": { "sni": ["${JUICITY_SNI}"] } }
              ],
              "handle": [
                {
                  "handler": "proxy",
                  "upstreams": [
                    { "dial": ["udp/127.0.0.1:${JUICITY_PORT}"] }
                  ]
                }
              ]
            }
          ]
        }
      }
    }
  }
}
EOF
fi

# 无论 config 是否已存在，都强制修复 owner/perm（幂等、抗迁移/覆盖）
chown root:"$CADDY_GROUP" "$CADDY_CONF" 2>/dev/null || true
chmod 0644 "$CADDY_CONF" 2>/dev/null || true
chmod 0755 /etc/caddy 2>/dev/null || true

cat >"$CADDY_SERVICE" <<'EOF'
[Unit]
Description=Caddy layer4 TCP+UDP 443 SNI proxy
After=network.target

[Service]
User=caddy
Group=caddy

StateDirectory=caddy
Environment=HOME=/var/lib/caddy
Environment=XDG_CONFIG_HOME=/var/lib/caddy/.config

ExecStart=/usr/local/bin/caddy-l4 run --config /etc/caddy/caddy.json
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144

Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

sed -i \
  -e "s|^User=caddy$|User=${CADDY_USER}|" \
  -e "s|^Group=caddy$|Group=${CADDY_GROUP}|" \
  -e "s|^ExecStart=/usr/local/bin/caddy-l4 run --config /etc/caddy/caddy.json$|ExecStart=${CADDY_BIN} run --config ${CADDY_CONF}|" \
  "$CADDY_SERVICE"

chmod 644 "$CADDY_SERVICE"

systemctl daemon-reload
systemctl enable "$CADDY_SERVICE_NAME" >/dev/null 2>&1 || true
systemctl restart "$CADDY_SERVICE_NAME"

echo "caddy-l4 updated to version: ${TAG}"
"$CADDY_BIN" version | head -n1
