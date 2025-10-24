#!/usr/bin/env bash
set -euo pipefail

# --- constants you may want to change ---
BIN_PATH="/usr/local/bin/hysteria"
CONF_DIR="/etc/hysteria"
CONF_FILE="${CONF_DIR}/config.yaml"
STATE_DIR="/var/lib/hysteria"
SYSTEMD_UNIT="/etc/systemd/system/hysteria-server.service"

HY2_API="https://api.hy2.io/v1"
REPO_BASE="https://github.com/apernet/hysteria/releases/download/app"

# 1. make sure curl exists (Debian 13.1 minimal often doesn't ship it)
apt-get update -y
apt-get install -y --no-install-recommends curl ca-certificates

# 2. detect arch (Debian on VPS is usually x86_64; we also support arm64 just in case)
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)   GOARCH="amd64" ;;
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

# 3. query the official hy2 API for the latest server release
tmpjson="$(mktemp)"
curl -sSL -f \
  "${HY2_API}/update?cver=deb13script&plat=linux&arch=${GOARCH}&chan=release&side=server" \
  -o "$tmpjson"

VERSION="$(grep -oP '"lver":\s*"\Kv[^"]+' "$tmpjson" | head -n1 || true)"
rm -f "$tmpjson"

if [ -z "$VERSION" ]; then
  echo "FATAL: cannot fetch latest Hysteria2 version"
  exit 1
fi

echo "[+] Hysteria2 latest version: $VERSION"

# 4. download that exact binary and install it
tmpbin="$(mktemp)"
URL="${REPO_BASE}/${VERSION}/hysteria-linux-${GOARCH}"
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

# 7. write systemd unit
cat >"$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} server --config ${CONF_FILE}
WorkingDirectory=${STATE_DIR}
User=hysteria
Group=hysteria
Environment=HYSTERIA_LOG_LEVEL=info

CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

LimitNOFILE=1048576
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

# 8. start + enable (autostart on boot)
systemctl daemon-reload
systemctl enable --now hysteria-server.service

echo
echo "[✓] Hysteria2 ${VERSION} is running and enabled (Debian 13.1 / xanmod ready)."
echo "[i] status : systemctl status hysteria-server.service"
echo "[i] logs   : journalctl -fu hysteria-server.service"
echo "[i] config : ${CONF_FILE}"
echo
