#!/usr/bin/env bash
# caddy-l4 UDP 443 SNI → TUIC / Juicity 分流（从 GitHub Releases 安静安装/更新）
set -euo pipefail

: "${TUIC_PORT:=4443}"
: "${JUICITY_PORT:=5443}"
: "${TUIC_SNI:=tuic.example.com}"
: "${JUICITY_SNI:=jc.example.com}"

: "${CADDY_USER:=caddy}"
: "${CADDY_GROUP:=caddy}"
: "${CADDY_BIN:=/usr/local/bin/caddy-l4}"
: "${CADDY_CONF:=/etc/caddy/caddy.json}"
: "${CADDY_SERVICE:=/etc/systemd/system/caddy-l4.service}"

: "${CADDY_REPO:=sealszzz/Caddy}"

export DEBIAN_FRONTEND=noninteractive

apt update -y >/dev/null
apt install -y --no-install-recommends curl ca-certificates tar >/dev/null

detect_arch() {
  local a
  a=$(dpkg --print-architecture 2>/dev/null || echo "")
  case "$a" in
    amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *)
      a=$(uname -m)
      case "$a" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)
          echo "FATAL: unsupported arch: $a" >&2
          exit 1
          ;;
      esac
      ;;
  esac
}

ARCH="$(detect_arch)"

LATEST_URL=$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
  "https://github.com/${CADDY_REPO}/releases/latest")
TAG="${LATEST_URL##*/}"

ASSET_NAME="caddy-l4-linux-${ARCH}-${TAG}.tar.gz"
ASSET_URL="https://github.com/${CADDY_REPO}/releases/download/${TAG}/${ASSET_NAME}"

TMP_DIR=$(mktemp -d /tmp/caddy-l4.XXXXXX)
trap 'rm -rf "${TMP_DIR}"' EXIT

if ! curl -fL -o "${TMP_DIR}/${ASSET_NAME}" "${ASSET_URL}"; then
  echo "FATAL: download failed: ${ASSET_URL}" >&2
  exit 1
fi

tar -xzf "${TMP_DIR}/${ASSET_NAME}" -C "${TMP_DIR}"

BIN_SRC="${TMP_DIR}/caddy-l4-linux-${ARCH}"
if [ ! -f "${BIN_SRC}" ]; then
  echo "FATAL: binary not found in tar: ${BIN_SRC}" >&2
  exit 1
fi

install -m 0755 "${BIN_SRC}" "${CADDY_BIN}"

getent group "${CADDY_GROUP}" >/dev/null || groupadd --system "${CADDY_GROUP}"

if ! id -u "${CADDY_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home \
    --gid "${CADDY_GROUP}" \
    --shell /usr/sbin/nologin \
    "${CADDY_USER}"
fi

HOME_DIR="/home/${CADDY_USER}"
mkdir -p "${HOME_DIR}/.config/caddy"
chown -R "${CADDY_USER}:${CADDY_GROUP}" "${HOME_DIR}"

mkdir -p /etc/caddy
chown -R "${CADDY_USER}:${CADDY_GROUP}" /etc/caddy

if [ ! -e "${CADDY_CONF}" ]; then
  cat > "${CADDY_CONF}" <<EOF
{
  "apps": {
    "layer4": {
      "servers": {
        "udpsni": {
          "listen": ["udp/:443"],
          "routes": [
            {
              "match": [{ "quic": { "sni": ["${TUIC_SNI}"] }}],
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
              "match": [{ "quic": { "sni": ["${JUICITY_SNI}"] }}],
              "handle": [
                {
                  "handler": "proxy",
                  "upstreams": [
                    { "dial": ["udp/127.0.0.1:${JUICITY_PORT}"] }
                  ]
                }
              ]
            },
            {
              "match": [{ "quic": {} }],
              "handle": [{ "handler": "echo" }]
            }
          ]
        }
      }
    }
  }
}
EOF
  chown "${CADDY_USER}:${CADDY_GROUP}" "${CADDY_CONF}"
  chmod 640 "${CADDY_CONF}"
fi

if [ ! -e "${CADDY_SERVICE}" ]; then
  cat > "${CADDY_SERVICE}" <<EOF
[Unit]
Description=Caddy layer4 UDP 443 SNI proxy (TUIC + Juicity)
After=network.target

[Service]
User=${CADDY_USER}
Group=${CADDY_GROUP}
ExecStart=${CADDY_BIN} run --config ${CADDY_CONF}
Restart=on-failure
RestartSec=5s
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable caddy-l4 >/dev/null 2>&1 || true

if systemctl is-active --quiet caddy-l4; then
  systemctl restart caddy-l4
else
  systemctl start caddy-l4
fi

echo "caddy-l4 updated to version: ${TAG}"
