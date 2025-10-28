#!/usr/bin/env bash
set -euo pipefail

# --- constants ---
BIN_PATH="/usr/local/bin/hysteria"
CONF_DIR="/etc/hysteria"
CONF_FILE="${CONF_DIR}/config.yaml"
STATE_DIR="/var/lib/hysteria"
SYSTEMD_UNIT="/etc/systemd/system/hysteria-server.service"

HY2_API="https://api.hy2.io/v1"
GITHUB_LATEST_API="https://api.github.com/repos/apernet/hysteria/releases/latest"
REPO_BASE="https://github.com/apernet/hysteria/releases/download/app"

# 1. make sure curl exists (Debian 13.1 minimal often doesn't ship it)
apt-get update -y
apt-get install -y --no-install-recommends curl ca-certificates

# 2. detect arch (Debian on VPS is usually x86_64; we also support arm64 just in case)
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)
    # Prefer AVX build if CPU supports AVX; fallback to amd64 otherwise
    if grep -qiE 'avx' /proc/cpuinfo 2>/dev/null; then
      GOARCH="amd64-avx"
    else
      GOARCH="amd64"
    fi
    ;;
  aarch64|arm64)  GOARCH="arm64" ;;
  armv7l|armv7)   GOARCH="arm" ;;
  s390x)          GOARCH="s390x" ;;
  loongarch64)    GOARCH="loong64" ;;
  i386|i686)      GOARCH="386" ;;
  *)
    echo "FATAL: unsupported arch: $arch"
    exit 1
    ;;
esac

# 3. query the official hy2 API for the latest server release (with GitHub fallback)
VERSION=""
tmpjson="$(mktemp)"
if curl -sSL -f \
  "${HY2_API}/update?cver=deb13script&plat=linux&arch=${GOARCH}&chan=release&side=server" \
  -o "$tmpjson"; then
  VERSION="$(grep -oP '"lver":\s*"\K[^"]+' "$tmpjson" | head -n1 || true)"
fi
rm -f "$tmpjson"

# fallback to GitHub Releases if HY2 API failed
if [ -z "${VERSION}" ]; then
  VERSION="$(curl -sSL -f "${GITHUB_LATEST_API}" \
             | grep -oP '"tag_name":\s*"\K[^"]+' \
             | head -n1 || true)"
fi

if [ -z "$VERSION" ]; then
  echo "FATAL: cannot fetch latest Hysteria2 version (both hy2 API and GitHub failed)."
  exit 1
fi

# Normalize tag: accept both 'app/vX.Y.Z' and 'vX.Y.Z'
TAG="${VERSION#app/}"
echo "[+] Hysteria2 latest version: $TAG (asset arch: ${GOARCH})"

# 4. download that exact binary and install it
tmpbin="$(mktemp)"
URL="${REPO_BASE}/${TAG}/hysteria-linux-${GOARCH}"
echo "[*] Downloading ${URL} ..."
curl -sSL -f -o "$tmpbin" "$URL"

echo "[*] Installing binary to ${BIN_PATH} ..."
install -Dm755 "$tmpbin" "$BIN_PATH"
rm -f "$tmpbin"

# 5. create dedicated system user (low-privilege sandbox for hy2)
if ! id hysteria >/dev/null 2>&1; then
  echo "[*] Creating system user 'hysteria' ..."
  useradd \
    --system \
    --home "${STATE_DIR}" \
    --create-home \
    --shell /usr/sbin/nologin \
    hysteria
fi

# 6. generate /etc/hysteria/config.yaml once (keep existing if already there)
if [ ! -e "$CONF_FILE" ]; then
  echo "[*] Generating ${CONF_FILE} ..."
  install -d -m 0755 "$CONF_DIR"

  pw="$(dd if=/dev/urandom bs=18 count=1 status=none | base64)"

  cat >"$CONF_FILE" <<EOF
listen: :8443

tls:
  cert: /etc/tls/cert.pem
  key: /etc/tls/key.pem

auth:
  type: password
  password: ${pw}
EOF

  # let only hysteria user read config (contains password)
  chown -R hysteria:hysteria "$CONF_DIR"
  chmod 600 "$CONF_FILE"
fi

echo "[i] Config: ${CONF_FILE} (password hidden)"
echo "[i] Make sure /etc/tls/cert.pem and /etc/tls/key.pem exist and are readable."

# 7. write systemd unit (expand variables at script time)
cat >"$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Hysteria 2 Server
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=hysteria
Group=hysteria
Type=simple
UMask=0077
ExecStart=${BIN_PATH} server --config ${CONF_FILE}
WorkingDirectory=${STATE_DIR}
Environment=HYSTERIA_LOG_LEVEL=info

CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

LimitNOFILE=262144
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

# 8. start + enable (autostart on boot)
systemctl daemon-reload
systemctl enable --now hysteria-server.service

echo
echo "[✓] Hysteria2 ${TAG} is running and enabled."
echo "[i] status : systemctl status hysteria-server.service"
echo "[i] logs   : journalctl -fu hysteria-server.service"
echo "[i] config : ${CONF_FILE}"
echo
