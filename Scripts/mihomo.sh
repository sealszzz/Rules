#!/usr/bin/env bash
set -euo pipefail

: "${MH_USER:=mihomo}"
: "${MH_GROUP:=mihomo}"
: "${MH_BIN:=/usr/local/bin/mihomo}"
: "${MH_CONF:=/etc/mihomo/config.yaml}"
: "${MH_SERVICE:=/etc/systemd/system/mihomo.service}"
: "${MH_REPO:=MetaCubeX/mihomo}"
: "${MH_PRERELEASE:=1}"

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

: "${REUSE_PASS:=}"
: "${REUSE_UUID:=}"
: "${SS2022_PASSWORD:=}"
: "${REALITY_SHORT_ID:=}"

: "${ANYTLS_USER:=anytls}"
: "${TRUSTTUNNEL_USER:=trusttunnel}"

export DEBIAN_FRONTEND=noninteractive

log(){ echo "[*] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

apt-get update >/dev/null
apt-get install -y --no-install-recommends curl ca-certificates openssl uuid-runtime jq gzip >/dev/null

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
      "https://github.com/${MH_REPO}/releases/latest"
  )"
  echo "${final##*/}"
}

gen_hex16()  { openssl rand -hex 16; }
gen_b64_16() { openssl rand -base64 16 | tr -d '\n'; }
gen_uuid()   { command -v uuidgen >/dev/null 2>&1 && uuidgen || cat /proc/sys/kernel/random/uuid; }
gen_sid8()   { openssl rand -hex 8; }

ARCH="$(detect_arch)"
TAG=""
ASSET_URL=""

if [ "${MH_PRERELEASE}" = "1" ]; then
  RELEASES_JSON="$(
    curl -fsSL -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${MH_REPO}/releases?per_page=50"
  )" || die "GitHub API failed (maybe rate-limited). Try: MH_PRERELEASE=0"

  TAG="$(
    echo "${RELEASES_JSON}" | jq -r \
      'map(select(.draft==false and .prerelease==true)) | .[0].tag_name // empty'
  )"
  [ -n "${TAG}" ] || die "no prerelease found (or API limited). Try: MH_PRERELEASE=0"

  ASSET_URL="$(
    echo "${RELEASES_JSON}" | jq -r --arg arch "${ARCH}" '
      map(select(.draft==false and .prerelease==true))
      | .[0].assets[]?
      | select(.name | test("^mihomo-linux-" + $arch + ".*\\.gz$"))
      | .browser_download_url
    ' | head -n1
  )"
  [ -n "${ASSET_URL}" ] && [ "${ASSET_URL}" != "null" ] \
    || die "asset not found in prerelease for arch=${ARCH}"
else
  TAG="$(get_latest_tag_302)" || die "cannot resolve latest stable tag via 302"

  RELEASE_JSON="$(
    curl -fsSL -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${MH_REPO}/releases/tags/${TAG}"
  )" || die "GitHub API failed for tag ${TAG}"

  ASSET_URL="$(
    echo "${RELEASE_JSON}" | jq -r --arg arch "${ARCH}" '
      .assets[]?
      | select(.name | test("^mihomo-linux-" + $arch + ".*\\.gz$"))
      | .browser_download_url
    ' | head -n1
  )"
  [ -n "${ASSET_URL}" ] && [ "${ASSET_URL}" != "null" ] \
    || die "asset not found for tag=${TAG} arch=${ARCH}"
fi

TMP_DIR="$(mktemp -d /tmp/mihomo.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

log "Download: ${ASSET_URL}"
curl -fL --retry 3 --retry-delay 1 \
  -o "${TMP_DIR}/mihomo.gz" \
  "${ASSET_URL}"

log "Install binary -> ${MH_BIN}"
gzip -dc "${TMP_DIR}/mihomo.gz" > "${MH_BIN}"
chmod 0755 "${MH_BIN}"

getent group "${MH_GROUP}" >/dev/null || groupadd --system "${MH_GROUP}"
if ! id -u "${MH_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home \
    --gid "${MH_GROUP}" \
    --shell /usr/sbin/nologin \
    "${MH_USER}"
fi

install -d -o root -g "${MH_GROUP}" -m 750 /etc/mihomo
install -d -o "${MH_USER}" -g "${MH_GROUP}" -m 750 /var/lib/mihomo

if [ ! -r "${CERT}" ] || [ ! -r "${KEY}" ]; then
  mkdir -p "$(dirname "${CERT}")"
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "${KEY}" -out "${CERT}" \
    -subj "/CN=www.microsoft.com" >/dev/null 2>&1
fi

if [ ! -f "${MH_CONF}" ]; then
  log "Create config: ${MH_CONF}"

  [ -n "${REUSE_PASS}" ]       || REUSE_PASS="$(gen_hex16)"
  [ -n "${REUSE_UUID}" ]       || REUSE_UUID="$(gen_uuid)"
  [ -n "${SS2022_PASSWORD}" ]  || SS2022_PASSWORD="$(gen_b64_16)"
  [ -n "${REALITY_SHORT_ID}" ] || REALITY_SHORT_ID="$(gen_sid8)"

  REALITY_KEYPAIR="$("${MH_BIN}" generate reality-keypair 2>/dev/null)" || die "generate reality-keypair failed"
  REALITY_PRIVATE_KEY="$(
    printf '%s\n' "${REALITY_KEYPAIR}" | awk -F': ' '/PrivateKey/ {print $2; exit}'
  )"
  REALITY_PUBLIC_KEY="$(
    printf '%s\n' "${REALITY_KEYPAIR}" | awk -F': ' '/PublicKey/ {print $2; exit}'
  )"

  [ -n "${REALITY_PRIVATE_KEY}" ] || die "reality private key empty"
  [ -n "${REALITY_PUBLIC_KEY}" ]  || die "reality public key empty"

  cat > "${MH_CONF}" <<EOF
log-level: warn
mode: direct
ipv6: true

dns:
  enable: true
  ipv6: false
  nameserver:
    - system

listeners:
  - name: shadowsocks-in
    type: shadowsocks
    listen: "::"
    port: 3443
    password: "${SS2022_PASSWORD}"
    cipher: 2022-blake3-aes-128-gcm
    udp: true

  - name: anytls-in
    type: anytls
    listen: "::"
    port: 4443
    users:
      "${ANYTLS_USER}": "${REUSE_PASS}"
    certificate: "${CERT}"
    private-key: "${KEY}"

  - name: tuic-in
    type: tuic
    listen: "::"
    port: 5443
    users:
      "${REUSE_UUID}": "${REUSE_PASS}"
    certificate: "${CERT}"
    private-key: "${KEY}"
    congestion-controller: bbr
    max-idle-time: 15000
    authentication-timeout: 1000
    alpn:
      - h3
    max-udp-relay-packet-size: 1500

  - name: vless-in
    type: vless
    listen: "::"
    port: 6443
    users:
      - username: "vless"
        uuid: "${REUSE_UUID}"
        flow: xtls-rprx-vision
    reality-config:
      dest: www.microsoft.com:443
      private-key: "${REALITY_PRIVATE_KEY}"
      public-key: "${REALITY_PUBLIC_KEY}"
      short-id:
        - "${REALITY_SHORT_ID}"
      server-names:
        - www.microsoft.com

  - name: trusttunnel-in
    type: trusttunnel
    listen: "::"
    port: 7443
    users:
      - username: "${TRUSTTUNNEL_USER}"
        password: "${REUSE_PASS}"
    certificate: "${CERT}"
    private-key: "${KEY}"
    network: ["tcp", "udp"]
    congestion-controller: bbr
EOF

  chown root:"${MH_GROUP}" "${MH_CONF}"
  chmod 640 "${MH_CONF}"
else
  log "Config exists, keep unchanged: ${MH_CONF}"
fi

if [ ! -f "${MH_SERVICE}" ]; then
  log "Create service: ${MH_SERVICE}"
  cat > "${MH_SERVICE}" <<EOF
[Unit]
Description=mihomo service
Documentation=https://wiki.metacubex.one/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${MH_USER}
Group=${MH_GROUP}
Type=simple
UMask=0077
WorkingDirectory=/var/lib/mihomo
ExecStart=${MH_BIN} -d /etc/mihomo
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "${MH_SERVICE}"
else
  log "Service exists, keep unchanged: ${MH_SERVICE}"
fi

systemctl daemon-reload
systemctl enable mihomo >/dev/null 2>&1 || true
systemctl restart mihomo

echo
echo "mihomo installed tag: ${TAG} (prerelease=${MH_PRERELEASE})"
"${MH_BIN}" -v 2>/dev/null || true
