#!/usr/bin/env bash
set -euo pipefail

: "${SN_PORT:=8443}"

SN_USER="snell"
SN_GROUP="snell"

SN_STATE_DIR="/var/lib/snell"
SN_CONF_DIR="/etc/snell"
SN_CONFIG="${SN_CONF_DIR}/snell.conf"

SN_BIN="/usr/local/bin/snell"

SERVICE_NAME="snell"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

export DEBIAN_FRONTEND=noninteractive

apt-get update >/dev/null
apt-get install -y --no-install-recommends \
  curl ca-certificates unzip iproute2 openssl >/dev/null

getent group "$SN_GROUP" >/dev/null || groupadd --system "$SN_GROUP"
id -u "$SN_USER" >/dev/null 2>&1 || \
  useradd --system -g "$SN_GROUP" -M -d "$SN_STATE_DIR" -s /usr/sbin/nologin "$SN_USER"

install -d -o "$SN_USER" -g "$SN_GROUP" -m 750 "$SN_STATE_DIR"
install -d -o root -g "$SN_GROUP" -m 750 "$SN_CONF_DIR"

html="$(curl -fsSL "https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell")" || { echo "FATAL: cannot fetch release page" >&2; exit 1; }

AVAILABLE_VERSIONS="$(
  printf '%s\n' "$html" \
    | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+' \
    | sed -E 's/^snell-server-//' \
    | sort -V \
    | uniq \
    | awk -F. '{ major=$1; latest[major]=$0 } END { for (m in latest) print latest[m] }' \
    | sort -V
)"

[ -n "$AVAILABLE_VERSIONS" ] || { echo "FATAL: cannot parse versions" >&2; exit 1; }

echo ""
PS3="请输入你要安装的版本对应的数字: "
select SN_VER in $AVAILABLE_VERSIONS; do
  if [ -n "$SN_VER" ]; then
    echo "==> 已选择: $SN_VER"
    break
  else
    echo "输入无效，请重新输入对应的数字。"
  fi
done

case "$(uname -m)" in
  x86_64|amd64)  SN_ARCH="linux-amd64" ;;
  aarch64|arm64) SN_ARCH="linux-aarch64" ;;
  *) echo "FATAL: unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

SN_ASSET="snell-server-${SN_VER}-${SN_ARCH}.zip"
SN_URL="https://dl.nssurge.com/snell/${SN_ASSET}"

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.zip" "$SN_URL"
unzip -q "$tmpd/pkg.zip" -d "$tmpd"

SN_SRC="$(find "$tmpd" -type f -name 'snell-server' -perm -u+x 2>/dev/null | head -n1 || true)"
[ -n "$SN_SRC" ] || { echo "FATAL: snell-server not found in asset" >&2; exit 1; }

install -m 0755 "$SN_SRC" "$SN_BIN"

if [ ! -f "$SN_CONFIG" ]; then
  PSK="$(openssl rand -hex 16)"

  cat >"$SN_CONFIG" <<EOF
[snell-server]
listen = ::0:${SN_PORT}
psk = ${PSK}
ipv6 = true
ip-version = prefer-v4
EOF

  chown root:"$SN_GROUP" "$SN_CONFIG"
  chmod 640 "$SN_CONFIG"

  echo "Snell PORT: ${SN_PORT}"
  echo "Snell PSK:  ${PSK}"
fi

if [ ! -f "$SERVICE_FILE" ]; then
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Snell Server
Documentation=https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${SN_USER}
Group=${SN_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${SN_STATE_DIR}
ExecStart=${SN_BIN} -c ${SN_CONFIG}
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SERVICE_FILE"
fi

systemctl daemon-reload
if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
  systemctl try-reload-or-restart "$SERVICE_NAME" || systemctl restart "$SERVICE_NAME"
else
  systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

echo "Snell BIN: $(
  "$SN_BIN" -v 2>&1 \
  | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
  | head -n1 \
  || echo '<unknown>'
)"
