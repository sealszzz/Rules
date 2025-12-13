#!/usr/bin/env bash
# caddy-l4 TCP+UDP 443 SNI STREAM (admin disabled, no home dir)
set -euo pipefail

# ===== Tunables =====
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

need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "FATAL: run as root"; exit 1; }; }
need_root

# ===== Deps (runtime only) =====
apt-get update >/dev/null
apt-get install -y --no-install-recommends curl ca-certificates tar >/dev/null

# ensure 'install' exists (some minimal images may lack it)
if ! command -v install >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends coreutils >/dev/null
fi

# ===== Arch =====
detect_arch() {
  case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    amd64|x86_64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *)
      echo "FATAL: unsupported arch: $(uname -m)" >&2
      exit 1
      ;;
  esac
}
ARCH="$(detect_arch)"

# ===== Resolve latest release via 302 =====
LATEST_URL="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${CADDY_REPO}/releases/latest")"
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

# ===== User / dirs (NO HOME) =====
getent group "$CADDY_GROUP" >/dev/null || groupadd --system "$CADDY_GROUP"

if ! id -u "$CADDY_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home \
    --gid "$CADDY_GROUP" \
    --shell /usr/sbin/nologin \
    "$CADDY_USER"
fi

mkdir -p /etc/caddy
chown root:"$CADDY_GROUP" /etc/caddy
chmod 750 /etc/caddy

# ===== Config (create-once) =====
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
  chown root:"$CADDY_GROUP" "$CADDY_CONF"
  chmod 640 "$CADDY_CONF"
fi

# validate config before (re)starting (official CLI command)
if ! "$CADDY_BIN" validate --config "$CADDY_CONF" >/dev/null 2>&1; then
  echo "FATAL: caddy config validation failed: $CADDY_CONF" >&2
  "$CADDY_BIN" validate --config "$CADDY_CONF" || true
  exit 1
fi

# ===== systemd (create-once) =====
if [ ! -f "$CADDY_SERVICE" ]; then
  cat >"$CADDY_SERVICE" <<EOF
[Unit]
Description=Caddy layer4 TCP+UDP 443 SNI proxy
After=network.target

[Service]
User=${CADDY_USER}
Group=${CADDY_GROUP}
ExecStart=${CADDY_BIN} run --config ${CADDY_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$CADDY_SERVICE"
fi

# ===== Start / restart =====
systemctl daemon-reload
systemctl enable "$CADDY_SERVICE_NAME" >/dev/null 2>&1 || true

if systemctl is-active --quiet "$CADDY_SERVICE_NAME"; then
  systemctl restart "$CADDY_SERVICE_NAME"
else
  systemctl start "$CADDY_SERVICE_NAME"
fi

echo "caddy-l4 updated to version: ${TAG}"
echo "[*] caddy-l4 binary version:"
"$CADDY_BIN" version 2>/dev/null || "$CADDY_BIN" -version 2>/dev/null || "$CADDY_BIN" --version 2>/dev/null || true
