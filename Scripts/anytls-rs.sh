#!/usr/bin/env bash
set -euo pipefail

: "${ANYTLS_PORT:=8443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${A_PASS:=}"
: "${ANYTLS_LOG_LEVEL:=info}"
: "${ANYTLS_WATCH_CERT:=1}"
: "${ANYTLS_SHOW_CERT_INFO:=0}"
: "${ANYTLS_EXPIRY_WARNING_DAYS:=30}"
: "${ANYTLS_IDLE_CHECK_INTERVAL:=30}"
: "${ANYTLS_IDLE_TIMEOUT:=120}"
: "${ANYTLS_MIN_IDLE_SESSION:=1}"

export DEBIAN_FRONTEND=noninteractive

apt-get update -yq
apt-get install -yq --no-install-recommends curl ca-certificates tar openssl

[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

getent group anytls >/dev/null || groupadd --system anytls
id -u anytls >/dev/null 2>&1 || useradd --system -g anytls -M -d /var/lib/anytls -s /usr/sbin/nologin anytls

install -d -o anytls -g anytls -m 750 /var/lib/anytls

TAG="$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/jxo-me/anytls-rs/releases/latest | grep -o '[^/]*$')"
[ -n "$TAG" ] || { echo "FATAL: failed to get latest tag"; exit 1; }

VER="${TAG#v}"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ASSET="anytls-linux-x86_64-${VER}.tar.gz" ;;
  aarch64|arm64) ASSET="anytls-linux-aarch64-${VER}.tar.gz" ;;
  *) echo "FATAL: unsupported arch $ARCH"; exit 1 ;;
esac

TMP_DIR="$(mktemp -d)"
curl -fL --retry 3 --retry-delay 1 -o "$TMP_DIR/pkg.tgz" "https://github.com/jxo-me/anytls-rs/releases/download/${TAG}/${ASSET}"
mkdir -p "$TMP_DIR/unpack"
tar -xzf "$TMP_DIR/pkg.tgz" -C "$TMP_DIR/unpack"

SERVER_BIN="$(find "$TMP_DIR/unpack" -type f -name anytls-server | head -n1 || true)"
[ -n "$SERVER_BIN" ] || { echo "FATAL: anytls-server not found"; exit 1; }

install -m 0755 "$SERVER_BIN" /usr/local/bin/anytls
rm -rf "$TMP_DIR"

FIRST_INSTALL=0
if [ ! -f /etc/systemd/system/anytls.service ]; then
  FIRST_INSTALL=1
  [ -n "$A_PASS" ] || A_PASS="$(openssl rand -hex 16)"

  EXEC_START="/usr/local/bin/anytls -l [::]:${ANYTLS_PORT} -p ${A_PASS} --cert ${CERT} --key ${KEY} -L ${ANYTLS_LOG_LEVEL} -I ${ANYTLS_IDLE_CHECK_INTERVAL} -T ${ANYTLS_IDLE_TIMEOUT} -M ${ANYTLS_MIN_IDLE_SESSION}"

  if [ "${ANYTLS_WATCH_CERT}" = "1" ]; then
    EXEC_START="${EXEC_START} --watch-cert"
  fi

  if [ "${ANYTLS_SHOW_CERT_INFO}" = "1" ]; then
    EXEC_START="${EXEC_START} --show-cert-info"
  fi

  if [ -n "${ANYTLS_EXPIRY_WARNING_DAYS}" ]; then
    EXEC_START="${EXEC_START} --expiry-warning-days ${ANYTLS_EXPIRY_WARNING_DAYS}"
  fi

  cat >/etc/systemd/system/anytls.service <<EOF
[Unit]
Description=AnyTLS Server (anytls-rs)
Documentation=https://github.com/jxo-me/anytls-rs
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=anytls
Group=anytls
Type=simple
UMask=0077
WorkingDirectory=/var/lib/anytls
ExecStart=${EXEC_START}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 /etc/systemd/system/anytls.service
fi

systemctl daemon-reload
systemctl enable --now anytls >/dev/null 2>&1 || systemctl restart anytls

BIN_VER="$(/usr/local/bin/anytls -V 2>/dev/null || /usr/local/bin/anytls --version 2>/dev/null || true)"
echo "anytls tag: ${TAG}"
echo "anytls bin: ${BIN_VER:-unknown}"
if [ "$FIRST_INSTALL" -eq 1 ]; then
  echo "anytls password: ${A_PASS}"
else
  echo "anytls password: (unchanged; check ExecStart in /etc/systemd/system/anytls.service)"
fi
