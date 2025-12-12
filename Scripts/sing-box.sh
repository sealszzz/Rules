#!/usr/bin/env bash
# sing-box anytls minimal installer: install/upgrade from GitHub Releases
set -euo pipefail

: "${SINGBOX_USER:=sing-box}"
: "${SINGBOX_GROUP:=sing-box}"
: "${SINGBOX_BIN:=/usr/local/bin/sing-box}"
: "${SINGBOX_CONF:=/etc/sing-box/config.json}"
: "${SINGBOX_SERVICE:=/etc/systemd/system/sing-box.service}"
: "${SINGBOX_REPO:=SagerNet/sing-box}"

: "${ANYTLS_PORT:=8443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${ANYTLS_PASSWORD:=}"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y >/dev/null
apt-get install -y --no-install-recommends curl ca-certificates tar openssl coreutils >/dev/null

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
  "https://github.com/${SINGBOX_REPO}/releases/latest")
VERSION="$(echo "${LATEST_URL}" | grep -oE '/v[0-9][0-9.]*$' | sed 's#/v##')"

if [ -z "${VERSION}" ]; then
  echo "FATAL: cannot parse latest version from ${LATEST_URL}" >&2
  exit 1
fi

TAG="v${VERSION}"
ASSET_NAME="sing-box-${VERSION}-linux-${ARCH}.tar.gz"
ASSET_URL="https://github.com/${SINGBOX_REPO}/releases/download/${TAG}/${ASSET_NAME}"

TMP_DIR="$(mktemp -d /tmp/sing-box.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "[*] downloading ${ASSET_URL}"
if ! curl -fL -o "${TMP_DIR}/${ASSET_NAME}" "${ASSET_URL}"; then
  echo "FATAL: download failed: ${ASSET_URL}" >&2
  exit 1
fi

echo "[*] extracting..."
tar -xzf "${TMP_DIR}/${ASSET_NAME}" -C "${TMP_DIR}"

BIN_DIR="${TMP_DIR}/sing-box-${VERSION}-linux-${ARCH}"
BIN_SRC="${BIN_DIR}/sing-box"

if [ ! -f "${BIN_SRC}" ]; then
  echo "FATAL: binary not found in tar: ${BIN_SRC}" >&2
  exit 1
fi

echo "[*] installing binary to ${SINGBOX_BIN}"
install -m 0755 "${BIN_SRC}" "${SINGBOX_BIN}"

getent group "${SINGBOX_GROUP}" >/dev/null || groupadd --system "${SINGBOX_GROUP}"

if ! id -u "${SINGBOX_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home \
    --gid "${SINGBOX_GROUP}" \
    --shell /usr/sbin/nologin \
    "${SINGBOX_USER}"
fi

mkdir -p /etc/sing-box /var/lib/sing-box
chown -R "${SINGBOX_USER}:${SINGBOX_GROUP}" /etc/sing-box /var/lib/sing-box

if [ -z "${ANYTLS_PASSWORD}" ]; then
  ANYTLS_PASSWORD="$(openssl rand -hex 16 || echo '0123456789abcdef0123456789abcdef')"
fi

if [ ! -e "${SINGBOX_CONF}" ]; then
  cat > "${SINGBOX_CONF}" <<EOF
{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "anytls",
      "listen": "::",
      "listen_port": ${ANYTLS_PORT},
      "users": [
        { "password": "${ANYTLS_PASSWORD}" }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT}",
        "key_path": "${KEY}"
      }
    }
  ],
  "outbounds": [
    { "type": "direct" }
  ]
}
EOF
  chown "${SINGBOX_USER}:${SINGBOX_GROUP}" "${SINGBOX_CONF}"
  chmod 640 "${SINGBOX_CONF}"
  echo "[*] created new config: ${SINGBOX_CONF}"
  echo "[*] anytls password: ${ANYTLS_PASSWORD}"
else
  echo "[*] existing config detected at ${SINGBOX_CONF}, not touching it."
fi

if [ ! -e "${SINGBOX_SERVICE}" ]; then
  cat > "${SINGBOX_SERVICE}" <<EOF
[Unit]
Description=sing-box service (anytls)
After=network.target

[Service]
User=${SINGBOX_USER}
Group=${SINGBOX_GROUP}
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONF}
WorkingDirectory=/var/lib/sing-box
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  echo "[*] created new service: ${SINGBOX_SERVICE}"
else
  echo "[*] existing service detected at ${SINGBOX_SERVICE}, not touching it."
fi

systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1 || true

if systemctl is-active --quiet sing-box; then
  systemctl restart sing-box
else
  systemctl start sing-box
fi

echo
echo "sing-box updated to version: ${TAG}"
"${SINGBOX_BIN}" version || true
