#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

: "${ANYTLS_LISTEN:=[::]}"
: "${ANYTLS_PORT:=4443}"
: "${ANYTLS_USER:=anytls}"
: "${ANYTLS_GROUP:=anytls}"
: "${ANYTLS_TAG:=}"
: "${ANYTLS_PASSWORD:=}"

ANYTLS_STATE_DIR="/var/lib/anytls"
ANYTLS_BIN="/usr/local/bin/anytls-server"
ANYTLS_SERVICE="/etc/systemd/system/anytls.service"
ANYTLS_SERVICE_NAME="anytls"

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates unzip openssl

getent group "$ANYTLS_GROUP" >/dev/null || groupadd --system "$ANYTLS_GROUP"
id -u "$ANYTLS_USER" >/dev/null 2>&1 || \
  useradd --system -g "$ANYTLS_GROUP" -M -d "$ANYTLS_STATE_DIR" -s /usr/sbin/nologin "$ANYTLS_USER"

install -d -o "$ANYTLS_USER" -g "$ANYTLS_GROUP" -m 750 "$ANYTLS_STATE_DIR"

if [ -n "$ANYTLS_TAG" ]; then
  tag="$ANYTLS_TAG"
else
  final_url="$(
    curl -fsSIL -o /dev/null -w '%{url_effective}' \
      https://github.com/anytls/anytls-go/releases/latest
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
  *) exit 1 ;;
esac

asset="anytls_${version}_${os}_${arch}.zip"
url="https://github.com/anytls/anytls-go/releases/download/${tag}/${asset}"

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

curl -fL "$url" -o "$tmpd/pkg.zip"
unzip -q "$tmpd/pkg.zip" -d "$tmpd"

[ -f "$tmpd/anytls-server" ] || exit 1
install -m 0755 "$tmpd/anytls-server" "$ANYTLS_BIN"

if [ ! -f "$ANYTLS_SERVICE" ]; then
  if [ -z "$ANYTLS_PASSWORD" ]; then
    ANYTLS_PASSWORD="$(openssl rand -hex 16)"
  fi
else
  if [ -z "$ANYTLS_PASSWORD" ]; then
    exit 1
  fi
fi

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
ExecStart=${ANYTLS_BIN} -l ${ANYTLS_LISTEN}:${ANYTLS_PORT} -p ${ANYTLS_PASSWORD}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$ANYTLS_SERVICE"
fi

systemctl daemon-reload
systemctl enable "$ANYTLS_SERVICE_NAME" >/dev/null 2>&1 || true
systemctl restart "$ANYTLS_SERVICE_NAME"

echo "anytls tag: ${tag}"
"$ANYTLS_BIN" --version 2>/dev/null | head -n1 || true
echo "anytls password: ${ANYTLS_PASSWORD}"
