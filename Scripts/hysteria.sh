#!/usr/bin/env bash
set -euo pipefail

# ===== Constants =====
BIN_PATH="/usr/local/bin/hysteria"
CONF_DIR="/etc/hysteria"
CONF_FILE="${CONF_DIR}/config.yaml"
STATE_DIR="/var/lib/hysteria"
SYSTEMD_UNIT="/etc/systemd/system/hysteria-server.service"
LOG_LEVEL="${LOG_LEVEL:-info}"

# Release endpoints
HY2_API="https://api.hy2.io/v1"
GITHUB_LATEST_API="https://api.github.com/repos/apernet/hysteria/releases/latest"
REPO_BASE="https://github.com/apernet/hysteria/releases/download"

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Please run as root."
    exit 1
  fi
}
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

need_root

# ===== Ensure curl =====
if ! have_cmd curl; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends curl ca-certificates
fi

# ===== Detect arch; API_ARCH 给接口用，ASSET_ARCH 用来选具体二进制 =====
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)
    API_ARCH="amd64"
    if grep -qiE 'avx' /proc/cpuinfo 2>/dev/null; then
      ASSET_ARCH="amd64-avx"
    else
      ASSET_ARCH="amd64"
    fi
    ;;
  aarch64|arm64) API_ARCH="arm64"; ASSET_ARCH="arm64" ;;
  armv7l|armv7)  API_ARCH="arm";   ASSET_ARCH="arm"   ;;
  *)
    echo "FATAL: unsupported arch: $arch"
    exit 1
    ;;
esac

# ===== Resolve latest version tag =====
VERSION=""
tmpjson="$(mktemp)"
if curl -fsSL "${HY2_API}/update?cver=deb13script&plat=linux&arch=${API_ARCH}&chan=release&side=server" -o "$tmpjson"; then
  VERSION="$(grep -oP '"lver":\s*"\K[^"]+' "$tmpjson" | head -n1 || true)"
fi
rm -f "$tmpjson"

# Fallback: GitHub Releases tag_name (形如 app/v2.x.y)
if [ -z "$VERSION" ]; then
  VERSION="$(curl -fsSL "${GITHUB_LATEST_API}" | grep -oP '"tag_name":\s*"\K[^"]+' | head -n1 || true)"
fi

if [ -z "$VERSION" ]; then
  echo "FATAL: cannot determine latest Hysteria2 version (hy2 API & GitHub both failed)."
  echo "Tip: fallback installer: bash <(curl -fsSL https://get.hy2.sh/)"
  exit 1
fi

echo "[+] Hysteria2 latest: ${VERSION} (asset: ${ASSET_ARCH})"

# ===== Download & install binary =====
tmpbin="$(mktemp)"
URL="${REPO_BASE}/${VERSION}/hysteria-linux-${ASSET_ARCH}"
echo "[*] Downloading ${URL} ..."
curl -fsSL -o "$tmpbin" "$URL"

echo "[*] Installing to ${BIN_PATH} ..."
install -Dm755 "$tmpbin" "$BIN_PATH"
rm -f "$tmpbin"

# ===== Create system user & state dir =====
if ! id hysteria >/dev/null 2>&1; then
  echo "[*] Creating system user 'hysteria' ..."
  useradd --system --home "${STATE_DIR}" --create-home --shell /usr/sbin/nologin hysteria
fi

# ===== Generate minimal server config on first install =====
if [ ! -e "$CONF_FILE" ]; then
  echo "[*] Generating ${CONF_FILE} ..."
  install -d -m 0750 -o hysteria -g hysteria "$CONF_DIR"

  if have_cmd openssl; then
    pw="$(openssl rand -base64 18 | tr -d '\n')"
  else
    pw="$(dd if=/dev/urandom bs=18 count=1 status=none | base64)"
  fi

  cat >"$CONF_FILE" <<EOF
# Minimal server config. Cert files are assumed ready.
listen: :8443

tls:
  cert: /etc/tls/cert.pem
  key: /etc/tls/key.pem

auth:
  type: password
  password: ${pw}

# Uncomment to enable HTTP camouflage via upstream site:
# masquerade:
#   type: proxy
#   proxy:
#     url: https://news.ycombinator.com/
#     rewriteHost: true
EOF

  chown -R hysteria:hysteria "$CONF_DIR"
  chmod 640 "$CONF_FILE"
fi

echo "[i] Config ready: ${CONF_FILE}"
echo "[i] Ensure /etc/tls/cert.pem and /etc/tls/key.pem exist."

# ===== systemd unit =====
cat >"$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Hysteria 2 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hysteria
Group=hysteria
ExecStart=${BIN_PATH} server --config ${CONF_FILE}
WorkingDirectory=${STATE_DIR}
Environment=HYSTERIA_LOG_LEVEL=${LOG_LEVEL}

CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
UMask=0077

PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
LockPersonality=true

LimitNOFILE=1048576
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

# ===== Enable & start =====
systemctl daemon-reload
systemctl enable --now hysteria-server.service

echo
"${BIN_PATH}" version || true
echo "[✓] Hysteria2 ${VERSION} installed, enabled and running."
echo "[i] status : systemctl status hysteria-server.service"
echo "[i] logs   : journalctl -fu hysteria-server.service"
echo "[i] config : ${CONF_FILE}"
echo
