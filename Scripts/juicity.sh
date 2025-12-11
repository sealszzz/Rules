#!/usr/bin/env bash
# juicity-min: no-API latest tag, glibc only (x86_64/arm64), plain binary install
set -euo pipefail

: "${J_PORT:=443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${J_CONG:=bbr}"            # bbr/cubic/new_reno
: "${J_LOG:=warn}"            # trace/debug/info/warn/error
: "${J_DISABLE_UDP443:=true}" # true/false

J_USER="juicity"
J_GROUP="juicity"

J_STATE_DIR="/var/lib/juicity"
J_ETC_DIR="/etc/juicity"
J_CONF="${J_ETC_DIR}/server.json"

J_BIN="/usr/local/bin/juicity-server"
J_SVC_NAME="juicity-server"
J_SVC="/etc/systemd/system/${J_SVC_NAME}.service"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y --no-install-recommends curl ca-certificates unzip openssl uuid-runtime iproute2

[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

getent group "$J_GROUP" >/dev/null || groupadd --system "$J_GROUP"
id -u "$J_USER" >/dev/null 2>&1 || \
  useradd --system -g "$J_GROUP" -M -d "$J_STATE_DIR" -s /usr/sbin/nologin "$J_USER"

install -d -o "$J_USER" -g "$J_GROUP" -m 750 "$J_STATE_DIR"
install -d -o root      -g "$J_GROUP" -m 750 "$J_ETC_DIR"

get_latest_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
      https://github.com/juicity/juicity/releases/latest)" || return 1
  printf '%s\n' "${u##*/}"
}
echo "[*] Query latest Juicity release (no-API)…"
TAG="$(get_latest_tag)" || { echo "Failed to resolve latest tag"; exit 1; }
echo "[*] Latest tag: $TAG"

# ---- 3) 选择并下载资产：juicity-linux-{x86_64|arm64}.zip ----
case "$(uname -m)" in
  x86_64|amd64)  ARCH="x86_64" ;;
  aarch64|arm64) ARCH="arm64"  ;;
  *) echo "Unsupported arch: $(uname -m) (x86_64/arm64 only)">&2; exit 1 ;;
esac

ASSET="juicity-linux-${ARCH}.zip"
BASE="https://github.com/juicity/juicity/releases/download/${TAG}/${ASSET}"

tmpd="$(mktemp -d)"
cleanup(){ rm -rf "$tmpd"; }
trap cleanup EXIT

zipfile="${tmpd}/${ASSET}"
echo "[*] Download: ${ASSET}"
curl -fL --retry 3 --retry-delay 1 -o "$zipfile" "$BASE"

work="${tmpd}/unz"
mkdir -p "$work"
unzip -q "$zipfile" -d "$work"

[ -f "${work}/juicity-server" ] || { echo "FATAL: juicity-server not found in zip"; exit 1; }
install -m 0755 "${work}/juicity-server" "$J_BIN"
rm -f "$zipfile"
rm -rf "$work"

if [ ! -f "$J_CONF" ]; then
  J_UUID="${J_UUID:-$(uuidgen)}"
  J_PASS="${J_PASS:-$(openssl rand -hex 16)}"

  cat >"$J_CONF" <<EOF
{
  "listen": "[::]:${J_PORT}",
  "users": {
    "${J_UUID}": "${J_PASS}"
  },
  "certificate": "${CERT}",
  "private_key": "${KEY}",
  "congestion_control": "${J_CONG}",
  "disable_outbound_udp443": ${J_DISABLE_UDP443},
  "log_level": "${J_LOG}"
}
EOF
  chown root:"$J_GROUP" "$J_CONF"
  chmod 0640 "$J_CONF"

  echo "JUICITY UUID: ${J_UUID}"
  echo "JUICITY PASS: ${J_PASS}"
fi

if [ ! -f "$J_SVC" ]; then
  cat >"$J_SVC" <<EOF
[Unit]
Description=Juicity Server
Documentation=https://github.com/juicity/juicity
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${J_USER}
Group=${J_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${J_STATE_DIR}
ExecStart=${J_BIN} run -c ${J_CONF} --disable-timestamp
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$J_SVC"
fi

systemctl daemon-reload
if systemctl is-enabled "$J_SVC_NAME" >/dev/null 2>&1; then
  systemctl try-reload-or-restart "$J_SVC_NAME" || systemctl restart "$J_SVC_NAME"
else
  systemctl enable --now "$J_SVC_NAME" || true
fi

echo
"$J_BIN" --version 2>/dev/null || true
echo "UDP/TCP ${J_PORT} 监听："
ss -Hnplu | grep -E ":${J_PORT}([^0-9]|$)" || echo "未见 UDP/${J_PORT} 占用（Juicity 走 QUIC/UDP）"
ss -Hnplt | grep -E ":${J_PORT}([^0-9]|$)" || true
