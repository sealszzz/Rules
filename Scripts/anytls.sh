#!/usr/bin/env bash
# anytls-go minimal installer (single-path, no fallback, no guessing)
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ===== Tunables =====
: "${ANYTLS_LISTEN:=[::]}"
: "${ANYTLS_PORT:=4443}"
: "${ANYTLS_USER:=anytls}"
: "${ANYTLS_GROUP:=anytls}"
: "${ANYTLS_TAG:=}"
: "${ANYTLS_PASSWORD:=}"
: "${ANYTLS_CERT:=/etc/tls/cert.pem}"
: "${ANYTLS_KEY:=/etc/tls/key.pem}"

ANYTLS_STATE_DIR="/var/lib/anytls"
ANYTLS_BIN="/usr/local/bin/anytls-server"
ANYTLS_SERVICE="/etc/systemd/system/anytls.service"

# ===== Deps =====
apt-get update
apt-get install -y --no-install-recommends \
  curl ca-certificates unzip openssl

# ===== User / dirs =====
getent group "$ANYTLS_GROUP" >/dev/null || groupadd --system "$ANYTLS_GROUP"
id -u "$ANYTLS_USER" >/dev/null 2>&1 || \
  useradd --system -g "$ANYTLS_GROUP" -M -d "$ANYTLS_STATE_DIR" -s /usr/sbin/nologin "$ANYTLS_USER"

install -d -o "$ANYTLS_USER" -g "$ANYTLS_GROUP" -m 750 "$ANYTLS_STATE_DIR"

# ===== Resolve tag via 302 =====
if [ -n "$ANYTLS_TAG" ]; then
  tag="$ANYTLS_TAG"
else
  final_url="$(
    curl -fsSIL -o /dev/null -w '%{url_effective}' \
      "https://github.com/anytls/anytls-go/releases/latest"
  )"
  tag="${final_url##*/}"
fi

case "$tag" in
  v*) version="${tag#v}" ;;
  *)  version="$tag"; tag="v${tag}" ;;
esac

case "$(uname -m)" in
  x86_64|amd64)  os="linux"; arch="amd64" ;;
  aarch64|arm64) os="linux"; arch="arm64" ;;
  *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

asset="anytls_${version}_${os}_${arch}.zip"
url="https://github.com/anytls/anytls-go/releases/download/${tag}/${asset}"

# ===== Download & install =====
tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

curl -fL "$url" -o "$tmpd/pkg.zip"
unzip -q "$tmpd/pkg.zip" -d "$tmpd"

bin="$(find "$tmpd" -maxdepth 1 -type f -name anytls-server -perm -u+x | head -n1)"
[ -n "$bin" ] || { echo "anytls-server not found in asset"; exit 1; }

install -m 0755 "$bin" "$ANYTLS_BIN"

# ===== Password rules (NO fallback) =====
if [ ! -f "$ANYTLS_SERVICE" ]; then
  if [ -z "$ANYTLS_PASSWORD" ]; then
    ANYTLS_PASSWORD="$(openssl rand -hex 16)"
  fi
else
  if [ -z "$ANYTLS_PASSWORD" ]; then
    echo "FATAL: ANYTLS_PASSWORD must be provided on re-run" >&2
    exit 1
  fi
fi

# ===== systemd unit (create-once) =====
if [ ! -f "$ANYTLS_SERVICE" ]; then
  cat >"$ANYTLS_SERVICE" <<EOF
[Unit]
Description=AnyTLS Server
Documentation=https://github.com/anytls/anytls-go
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${ANYTLS_USER}
Group=${ANYTLS_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${ANYTLS_STATE_DIR}
ExecStart=${ANYTLS_BIN} -l ${ANYTLS_LISTEN}:${ANYTLS_PORT} -p ${ANYTLS_PASSWORD} # -c ${ANYTLS_CERT} -k ${ANYTLS_KEY}
Restart=on-failure
RestartSec=3s
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$ANYTLS_SERVICE"
fi

# ===== Start =====
systemctl daemon-reload
systemctl enable anytls >/dev/null 2>&1 || true
systemctl restart anytls

# ===== Final output (ONLY versions) =====
echo "anytls tag: ${tag}"
echo "anytls bin: $("$ANYTLS_BIN" --version 2>/dev/null | head -n1)"
