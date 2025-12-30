#!/usr/bin/env bash
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
: "${SINGBOX_TAG:=}"

: "${TUIC_PORT:=8443}"
: "${TUIC_UUID:=}"
: "${TUIC_PASSWORD:=}"

export DEBIAN_FRONTEND=noninteractive

apt-get update >/dev/null
apt-get install -y --no-install-recommends curl ca-certificates tar openssl >/dev/null

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

get_latest_tag_302() {
  if [ -n "${SINGBOX_TAG}" ]; then
    printf '%s\n' "${SINGBOX_TAG}"
    return 0
  fi
  local final
  final="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
    "https://github.com/${SINGBOX_REPO}/releases/latest")" || return 1
  printf '%s\n' "${final##*/}"
}

ARCH="$(detect_arch)"
TAG="$(get_latest_tag_302)" || { echo "FATAL: cannot resolve latest stable tag via 302"; exit 1; }

case "$TAG" in
  v*) VERSION="${TAG#v}" ;;
  *)  VERSION="$TAG"; TAG="v$TAG" ;;
esac

ASSET_NAME="sing-box-${VERSION}-linux-${ARCH}.tar.gz"
ASSET_URL="https://github.com/${SINGBOX_REPO}/releases/download/${TAG}/${ASSET_NAME}"

TMP_DIR="$(mktemp -d /tmp/sing-box.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "[*] Download: ${ASSET_URL}"
curl -fL --retry 3 --retry-delay 1 -o "${TMP_DIR}/${ASSET_NAME}" "${ASSET_URL}"

echo "[*] Extract..."
tar -xzf "${TMP_DIR}/${ASSET_NAME}" -C "${TMP_DIR}"

BIN_DIR="${TMP_DIR}/sing-box-${VERSION}-linux-${ARCH}"
BIN_SRC="${BIN_DIR}/sing-box"
[ -f "${BIN_SRC}" ] || { echo "FATAL: binary not found: ${BIN_SRC}"; exit 1; }

echo "[*] Install binary -> ${SINGBOX_BIN}"
install -m 0755 "${BIN_SRC}" "${SINGBOX_BIN}"

getent group "${SINGBOX_GROUP}" >/dev/null || groupadd --system "${SINGBOX_GROUP}"
if ! id -u "${SINGBOX_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home --gid "${SINGBOX_GROUP}" --shell /usr/sbin/nologin "${SINGBOX_USER}"
fi

install -d -o root -g "${SINGBOX_GROUP}" -m 750 /etc/sing-box
install -d -o "${SINGBOX_USER}" -g "${SINGBOX_GROUP}" -m 750 /var/lib/sing-box

if [ ! -f "${SINGBOX_CONF}" ]; then
  [ -r "${CERT}" ] || { echo "FATAL: missing ${CERT}"; exit 1; }
  [ -r "${KEY}"  ] || { echo "FATAL: missing ${KEY}";  exit 1; }

  if [ -z "${ANYTLS_PASSWORD}" ]; then
    ANYTLS_PASSWORD="$(openssl rand -hex 16)"
  fi

  if [ -z "${TUIC_UUID}" ]; then
    if command -v uuidgen >/dev/null 2>&1; then
      TUIC_UUID="$(uuidgen)"
    else
      TUIC_UUID="$(cat /proc/sys/kernel/random/uuid)"
    fi
  fi

  if [ -z "${TUIC_PASSWORD}" ]; then
    TUIC_PASSWORD="$(openssl rand -hex 16)"
  fi

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
        {
          "password": "${ANYTLS_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT}",
        "key_path": "${KEY}"
      }
    },
    {
      "type": "tuic",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "users": [
        {
          "uuid": "${TUIC_UUID}",
          "password": "${TUIC_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT}",
        "key_path": "${KEY}",
        "alpn": ["h3"]
      },
      "congestion_control": "bbr",
      "zero_rtt_handshake": false,
      "heartbeat": "10s"
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF
  chown root:"${SINGBOX_GROUP}" "${SINGBOX_CONF}"
  chmod 640 "${SINGBOX_CONF}"
  echo "[*] Created config: ${SINGBOX_CONF}"
  echo "[*] AnyTLS password: ${ANYTLS_PASSWORD}"
  echo "[*] TUIC uuid: ${TUIC_UUID}"
  echo "[*] TUIC password: ${TUIC_PASSWORD}"
else
  echo "[*] Config exists, keep unchanged: ${SINGBOX_CONF}"
fi

if [ ! -f "${SINGBOX_SERVICE}" ]; then
  cat > "${SINGBOX_SERVICE}" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${SINGBOX_USER}
Group=${SINGBOX_GROUP}
Type=simple
UMask=0077
WorkingDirectory=/var/lib/sing-box
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "${SINGBOX_SERVICE}"
  echo "[*] Created service: ${SINGBOX_SERVICE}"
else
  echo "[*] Service exists, keep unchanged: ${SINGBOX_SERVICE}"
fi

systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl restart sing-box

echo
echo "sing-box installed tag: ${TAG} (stable via /releases/latest 302)"
"${SINGBOX_BIN}" version 2>/dev/null || true
