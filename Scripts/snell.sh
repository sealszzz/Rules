#!/usr/bin/env bash
# snell-min: latest snell-server, first-run config, later runs only update binary
set -euo pipefail

: "${SN_PORT:=8448}"
: "${SN_PSK:=}"
: "${SN_USER:=snell}"
: "${SN_GROUP:=${SN_USER}}"

SN_STATE_DIR="/var/lib/snell"
SN_CONF_DIR="/etc/snell"
SN_CONFIG="${SN_CONF_DIR}/snell-server.conf"
SN_BIN="/usr/local/bin/snell-server"

SERVICE_NAME="snell"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y --no-install-recommends curl ca-certificates unzip iproute2

getent group "$SN_GROUP" >/dev/null || groupadd --system "$SN_GROUP"
id -u "$SN_USER" >/dev/null 2>&1 || \
  useradd --system -g "$SN_GROUP" -M -d "$SN_STATE_DIR" -s /usr/sbin/nologin "$SN_USER"

install -d -o "$SN_USER" -g "$SN_GROUP" -m 750 "$SN_STATE_DIR"
install -d -o root      -g "$SN_GROUP" -m 750 "$SN_CONF_DIR"

get_latest_version() {
  local html ver
  html="$(curl -fsSL "https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell")" || return 1
  ver="$(
    printf '%s\n' "$html" \
      | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+' \
      | sed -E 's/^snell-server-//' \
      | sort -V \
      | tail -n1
  )"
  [ -n "$ver" ] || return 1
  printf '%s\n' "$ver"
}

echo "[*] Query latest Snell release…"
SN_VER="$(get_latest_version)" || { echo "Failed to resolve latest version"; exit 1; }

case "$(uname -m)" in
  x86_64|amd64)  SN_ARCH="linux-amd64"   ;;
  aarch64|arm64) SN_ARCH="linux-aarch64" ;;
  *)
    echo "Unsupported arch: $(uname -m) (x86_64/aarch64 only)" >&2
    exit 1
    ;;
esac

SN_ASSET="snell-server-${SN_VER}-${SN_ARCH}.zip"
SN_URL="https://dl.nssurge.com/snell/${SN_ASSET}"

echo "[*] Install version: ${SN_VER}"
echo "[*] Asset:           ${SN_ASSET}"

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
zipfile="${tmpd}/${SN_ASSET}"

curl -fL --retry 3 --retry-delay 1 -o "$zipfile" "$SN_URL"

work="${tmpd}/unz"
mkdir -p "$work"
unzip -q "$zipfile" -d "$work"

SN_SRC="$(find "$work" -maxdepth 1 -type f -name 'snell-server' -perm -u+x | head -n1 || true)"
[ -n "$SN_SRC" ] || { echo "FATAL: snell-server not found in asset"; exit 1; }

install -m 0755 "$SN_SRC" "$SN_BIN"

if [ ! -f "$SN_CONFIG" ]; then
  SN_PSK="${SN_PSK:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || echo 'SnellDefaultPSK12345')}"

  cat >"$SN_CONFIG" <<EOF
[snell-server]
listen = ::0:${SN_PORT}
psk = ${SN_PSK}
ipv6 = true
EOF

  chown root:"$SN_GROUP" "$SN_CONFIG"
  chmod 640 "$SN_CONFIG"

  echo "Snell PORT: ${SN_PORT}"
  echo "Snell PSK:  ${SN_PSK}"
fi

if [ ! -f "$SERVICE_FILE" ]; then
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Snell Server
Documentation=https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${SN_USER}
Group=${SN_USER}
Type=simple
UMask=0077
WorkingDirectory=${SN_STATE_DIR}
ExecStart=${SN_BIN} -c ${SN_CONFIG}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
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
  systemctl enable --now "$SERVICE_NAME" || true
fi

echo
"$SN_BIN" -v 2>/dev/null || true
echo "UDP/${SN_PORT} 监听检查："
ss -Hnplu 2>/dev/null | grep -E ":${SN_PORT}([^0-9]|$)" || echo "未见 UDP/${SN_PORT} 占用"
