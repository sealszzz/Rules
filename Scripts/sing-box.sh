#!/usr/bin/env bash
set -euo pipefail

: "${SINGBOX_USER:=sing-box}"
: "${SINGBOX_GROUP:=sing-box}"
: "${SINGBOX_BIN:=/usr/local/bin/sing-box}"
: "${SINGBOX_CONF:=/etc/sing-box/config.json}"
: "${SINGBOX_SERVICE:=/etc/systemd/system/sing-box.service}"
: "${SINGBOX_REPO:=SagerNet/sing-box}"

: "${SINGBOX_PRERELEASE:=1}"   # 1=latest pre-release (API) [default] ; 0=latest stable (302)

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

: "${ANYTLS_PORT:=8443}"
: "${ANYTLS_PASSWORD:=}"

: "${TUIC_PORT:=8443}"
: "${TUIC_UUID:=}"
: "${TUIC_PASSWORD:=}"

: "${HY2_PORT:=4443}"              # MUST NOT equal TUIC_PORT (both UDP/QUIC)
: "${HY2_NAME:=user}"
: "${HY2_PASSWORD:=}"
: "${HY2_OBFS_TYPE:=salamander}"   # salamander | none
: "${HY2_OBFS_PASSWORD:=}"
: "${HY2_UP_MBPS:=}"               # set BOTH up+down to enable
: "${HY2_DOWN_MBPS:=}"

export DEBIAN_FRONTEND=noninteractive

log(){ echo "[*] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

apt-get update >/dev/null
apt-get install -y --no-install-recommends curl ca-certificates tar openssl uuid-runtime iproute2 jq >/dev/null

detect_arch() {
  case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    amd64|x86_64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) die "unsupported arch: $(uname -m)" ;;
  esac
}

get_latest_tag_302() {
  local final
  final="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${SINGBOX_REPO}/releases/latest")"
  echo "${final##*/}"
}

gen_hex16(){ openssl rand -hex 16; }
gen_uuid(){ command -v uuidgen >/dev/null 2>&1 && uuidgen || cat /proc/sys/kernel/random/uuid; }

ARCH="$(detect_arch)"
SUFFIX="-glibc"   # only glibc assets
TAG=""
VERSION=""
ASSET_URL=""

# ---- resolve download URL ----
if [ "${SINGBOX_PRERELEASE}" = "1" ]; then
  # latest prerelease via API (no token)
  RELEASE_JSON="$(curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${SINGBOX_REPO}/releases?per_page=50")" \
    || die "GitHub API failed (maybe rate-limited). Try: SINGBOX_PRERELEASE=0"

  TAG="$(echo "${RELEASE_JSON}" | jq -r 'map(select(.draft==false and .prerelease==true)) | .[0].tag_name // empty')"
  [ -n "${TAG}" ] || die "no prerelease found (or API limited). Try: SINGBOX_PRERELEASE=0"

  VERSION="${TAG#v}"
  ASSET_NAME="sing-box-${VERSION}-linux-${ARCH}${SUFFIX}.tar.gz"

  ASSET_URL="$(echo "${RELEASE_JSON}" | jq -r --arg name "${ASSET_NAME}" '
    map(select(.draft==false and .prerelease==true)) | .[0].assets[]? | select(.name==$name) | .browser_download_url
  ' | head -n1)"

  [ -n "${ASSET_URL}" ] && [ "${ASSET_URL}" != "null" ] || die "asset not found in prerelease: ${ASSET_NAME}"
else
  TAG="$(get_latest_tag_302)" || die "cannot resolve latest stable tag via 302"
  VERSION="${TAG#v}"
  ASSET_NAME="sing-box-${VERSION}-linux-${ARCH}${SUFFIX}.tar.gz"
  ASSET_URL="https://github.com/${SINGBOX_REPO}/releases/download/${TAG}/${ASSET_NAME}"
fi

# ---- download & install ----
TMP_DIR="$(mktemp -d /tmp/sing-box.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

log "Download: ${ASSET_URL}"
curl -fL --retry 3 --retry-delay 1 -o "${TMP_DIR}/${ASSET_NAME}" "${ASSET_URL}"

log "Extract..."
tar -xzf "${TMP_DIR}/${ASSET_NAME}" -C "${TMP_DIR}"

BIN_DIR="${TMP_DIR}/${ASSET_NAME%.tar.gz}"
BIN_SRC="${BIN_DIR}/sing-box"
[ -f "${BIN_SRC}" ] || die "binary not found: ${BIN_SRC}"

log "Install binary -> ${SINGBOX_BIN}"
install -m 0755 "${BIN_SRC}" "${SINGBOX_BIN}"

# ---- user & dirs ----
getent group "${SINGBOX_GROUP}" >/dev/null || groupadd --system "${SINGBOX_GROUP}"
if ! id -u "${SINGBOX_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home --gid "${SINGBOX_GROUP}" --shell /usr/sbin/nologin "${SINGBOX_USER}"
fi

install -d -o root -g "${SINGBOX_GROUP}" -m 750 /etc/sing-box
install -d -o "${SINGBOX_USER}" -g "${SINGBOX_GROUP}" -m 750 /var/lib/sing-box

[ -r "${CERT}" ] || die "missing ${CERT}"
[ -r "${KEY}"  ] || die "missing ${KEY}"

# ---- sanity ----
if [ "${HY2_PORT}" = "${TUIC_PORT}" ]; then
  die "HY2_PORT must NOT equal TUIC_PORT (both are UDP/QUIC)."
fi
case "${HY2_OBFS_TYPE}" in salamander|none) ;; *) die "HY2_OBFS_TYPE must be salamander|none" ;; esac
if [ -n "${HY2_UP_MBPS}" ] || [ -n "${HY2_DOWN_MBPS}" ]; then
  [ -n "${HY2_UP_MBPS}" ] && [ -n "${HY2_DOWN_MBPS}" ] || die "set BOTH HY2_UP_MBPS and HY2_DOWN_MBPS, or leave both empty"
fi

CREATED_CONF=0

# ===== config: create only if missing =====
if [ ! -f "${SINGBOX_CONF}" ]; then
  CREATED_CONF=1
  log "Create config: ${SINGBOX_CONF}"

  [ -n "${ANYTLS_PASSWORD}" ] || ANYTLS_PASSWORD="$(gen_hex16)"
  [ -n "${TUIC_UUID}" ]      || TUIC_UUID="$(gen_uuid)"
  [ -n "${TUIC_PASSWORD}" ]  || TUIC_PASSWORD="$(gen_hex16)"
  [ -n "${HY2_PASSWORD}" ]   || HY2_PASSWORD="$(gen_hex16)"

  HY2_OBFS_LINES=""
  if [ "${HY2_OBFS_TYPE}" = "salamander" ]; then
    [ -n "${HY2_OBFS_PASSWORD}" ] || HY2_OBFS_PASSWORD="$(gen_hex16)"
    HY2_OBFS_LINES=$(cat <<EOF
      "obfs": {
        "type": "salamander",
        "password": "${HY2_OBFS_PASSWORD}"
      },
EOF
)
  fi

  HY2_RATE_LINES=""
  if [ -n "${HY2_UP_MBPS}" ] && [ -n "${HY2_DOWN_MBPS}" ]; then
    HY2_RATE_LINES=$(cat <<EOF
      "ignore_client_bandwidth": false,
      "up_mbps": ${HY2_UP_MBPS},
      "down_mbps": ${HY2_DOWN_MBPS},
EOF
)
  else
    HY2_RATE_LINES=$(cat <<EOF
      "ignore_client_bandwidth": true,
EOF
)
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
      "zero_rtt_handshake": false
    },
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": ${HY2_PORT},
${HY2_OBFS_LINES}      "users": [
        {
          "name": "${HY2_NAME}",
          "password": "${HY2_PASSWORD}"
        }
      ],
${HY2_RATE_LINES}      "tls": {
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

  chown root:"${SINGBOX_GROUP}" "${SINGBOX_CONF}"
  chmod 640 "${SINGBOX_CONF}"
else
  log "Config exists, keep unchanged: ${SINGBOX_CONF}"
fi

# ===== service: create only if missing =====
if [ ! -f "${SINGBOX_SERVICE}" ]; then
  log "Create service: ${SINGBOX_SERVICE}"
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
else
  log "Service exists, keep unchanged: ${SINGBOX_SERVICE}"
fi

systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl restart sing-box

echo
echo "sing-box installed tag: ${TAG} (prerelease=${SINGBOX_PRERELEASE}, libc=glibc)"
"${SINGBOX_BIN}" version 2>/dev/null || true

echo
if [ "${CREATED_CONF}" = "1" ]; then
  echo "[*] ====== Credentials (config was created) ======"
  echo "[*] AnyTLS port: ${ANYTLS_PORT}"
  echo "[*] AnyTLS pass: ${ANYTLS_PASSWORD}"
  echo "[*] TUIC  port: ${TUIC_PORT}"
  echo "[*] TUIC  uuid: ${TUIC_UUID}"
  echo "[*] TUIC  pass: ${TUIC_PASSWORD}"
  echo "[*] HY2   port: ${HY2_PORT}"
  echo "[*] HY2   user: ${HY2_NAME}"
  echo "[*] HY2   pass: ${HY2_PASSWORD}"
  echo "[*] HY2   obfs: ${HY2_OBFS_TYPE}"
  if [ "${HY2_OBFS_TYPE}" = "salamander" ]; then
    echo "[*] HY2 obfs pass: ${HY2_OBFS_PASSWORD}"
  fi
  if [ -n "${HY2_UP_MBPS}" ] && [ -n "${HY2_DOWN_MBPS}" ]; then
    echo "[*] HY2 rate limit: up=${HY2_UP_MBPS} down=${HY2_DOWN_MBPS} (ignore_client_bandwidth=false)"
  else
    echo "[*] HY2 rate limit: disabled (ignore_client_bandwidth=true)"
  fi
else
  echo "[*] Config already existed, so credentials were NOT regenerated."
fi
