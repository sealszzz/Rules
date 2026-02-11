#!/usr/bin/env bash
set -euo pipefail

: "${SB_USER:=sing-box}"
: "${SB_GROUP:=sing-box}"
: "${SB_BIN:=/usr/local/bin/sing-box}"
: "${SB_CONF:=/etc/sing-box/config.json}"
: "${SB_SERVICE:=/etc/systemd/system/sing-box.service}"
: "${SB_REPO:=SagerNet/sing-box}"
: "${SB_PRERELEASE:=1}"

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

: "${REUSE_PASS:=}"
: "${REUSE_UUID:=}"
: "${REUSE_SNI:=example.com}"
: "${NAIVE_USER:=naive}"
: "${HY2_USER:=hysteria2}"

: "${SB_SUFFIX:=-glibc}"

export DEBIAN_FRONTEND=noninteractive

log(){ echo "[*] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

apt-get update >/dev/null
apt-get install -y --no-install-recommends curl ca-certificates tar openssl uuid-runtime jq >/dev/null

detect_arch() {
  case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    amd64|x86_64)
      echo "amd64"
      ;;
    arm64|aarch64)
      echo "arm64"
      ;;
    *)
      die "unsupported arch: $(uname -m)"
      ;;
  esac
}

get_latest_tag_302() {
  local final
  final="$(
    curl -fsSIL -o /dev/null -w '%{url_effective}' \
      "https://github.com/${SB_REPO}/releases/latest"
  )"
  echo "${final##*/}"
}

gen_hex16() { openssl rand -hex 16; }
gen_uuid()  { command -v uuidgen >/dev/null 2>&1 && uuidgen || cat /proc/sys/kernel/random/uuid; }

ARCH="$(detect_arch)"
TAG=""
VERSION=""
ASSET_NAME=""
ASSET_URL=""

if [ "${SB_PRERELEASE}" = "1" ]; then
  RELEASES_JSON="$(
    curl -fsSL -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${SB_REPO}/releases?per_page=50"
  )" || die "GitHub API failed (maybe rate-limited). Try: SB_PRERELEASE=0"

  TAG="$(
    echo "${RELEASES_JSON}" | jq -r \
      'map(select(.draft==false and .prerelease==true)) | .[0].tag_name // empty'
  )"
  [ -n "${TAG}" ] || die "no prerelease found (or API limited). Try: SB_PRERELEASE=0"

  VERSION="${TAG#v}"
  ASSET_NAME="sing-box-${VERSION}-linux-${ARCH}${SB_SUFFIX}.tar.gz"

  ASSET_URL="$(
    echo "${RELEASES_JSON}" | jq -r --arg name "${ASSET_NAME}" '
      map(select(.draft==false and .prerelease==true))
      | .[0].assets[]?
      | select(.name==$name)
      | .browser_download_url
    ' | head -n1
  )"
  [ -n "${ASSET_URL}" ] && [ "${ASSET_URL}" != "null" ] \
    || die "asset not found in prerelease: ${ASSET_NAME}"
else
  TAG="$(get_latest_tag_302)" || die "cannot resolve latest stable tag via 302"
  VERSION="${TAG#v}"
  ASSET_NAME="sing-box-${VERSION}-linux-${ARCH}${SB_SUFFIX}.tar.gz"
  ASSET_URL="https://github.com/${SB_REPO}/releases/download/${TAG}/${ASSET_NAME}"
fi

TMP_DIR="$(mktemp -d /tmp/sing-box.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

log "Download: ${ASSET_URL}"
curl -fL --retry 3 --retry-delay 1 \
  -o "${TMP_DIR}/${ASSET_NAME}" \
  "${ASSET_URL}"

log "Extract..."
tar -xzf "${TMP_DIR}/${ASSET_NAME}" -C "${TMP_DIR}"

BIN_DIR="${TMP_DIR}/${ASSET_NAME%.tar.gz}"
BIN_SRC="${BIN_DIR}/sing-box"
[ -f "${BIN_SRC}" ] || die "binary not found: ${BIN_SRC}"

log "Install binary -> ${SB_BIN}"
install -m 0755 "${BIN_SRC}" "${SB_BIN}"

getent group "${SB_GROUP}" >/dev/null || groupadd --system "${SB_GROUP}"
if ! id -u "${SB_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home \
    --gid "${SB_GROUP}" \
    --shell /usr/sbin/nologin \
    "${SB_USER}"
fi

install -d -o root -g "${SB_GROUP}" -m 750 /etc/sing-box
install -d -o "${SB_USER}" -g "${SB_GROUP}" -m 750 /var/lib/sing-box

[ -r "${CERT}" ] || die "missing ${CERT}"
[ -r "${KEY}"  ] || die "missing ${KEY}"

if [ ! -f "${SB_CONF}" ]; then
  log "Create config: ${SB_CONF}"

  [ -n "${REUSE_PASS}" ] || REUSE_PASS="$(gen_hex16)"
  [ -n "${REUSE_UUID}" ] || REUSE_UUID="$(gen_uuid)"

  cat > "${SB_CONF}" <<EOF
{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": 4443,
      "users": [
        {
          "password": "${REUSE_PASS}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT}",
        "key_path": "${KEY}"
      }
    },
    {
      "type": "naive",
      "tag": "naive-in",
      "listen": "::",
      "listen_port": 5443,
      "network": "tcp",
      "users": [
        {
          "username": "${NAIVE_USER}",
          "password": "${REUSE_PASS}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REUSE_SNI}",
        "certificate_path": "${CERT}",
        "key_path": "${KEY}"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": 4443,
      "users": [
        {
          "uuid": "${REUSE_UUID}",
          "password": "${REUSE_PASS}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT}",
        "key_path": "${KEY}",
        "alpn": [
          "h3"
        ]
      },
      "congestion_control": "bbr",
      "zero_rtt_handshake": false
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 5443,
      "obfs": {
        "type": "salamander",
        "password": "${REUSE_PASS}"
      },
      "users": [
        {
          "name": "${HY2_USER}",
          "password": "${REUSE_PASS}"
        }
      ],
      "ignore_client_bandwidth": true,
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT}",
        "key_path": "${KEY}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

  chown root:"${SB_GROUP}" "${SB_CONF}"
  chmod 640 "${SB_CONF}"
else
  log "Config exists, keep unchanged: ${SB_CONF}"
fi

if [ ! -f "${SB_SERVICE}" ]; then
  log "Create service: ${SB_SERVICE}"
  cat > "${SB_SERVICE}" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${SB_USER}
Group=${SB_GROUP}
Type=simple
UMask=0077
WorkingDirectory=/var/lib/sing-box
ExecStartPre=${SB_BIN} check -c ${SB_CONF}
ExecStart=${SB_BIN} run -c ${SB_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "${SB_SERVICE}"
else
  log "Service exists, keep unchanged: ${SB_SERVICE}"
fi

systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl restart sing-box

echo
echo "sing-box installed tag: ${TAG} (prerelease=${SB_PRERELEASE}, libc=glibc)"
"${SB_BIN}" version 2>/dev/null || true
