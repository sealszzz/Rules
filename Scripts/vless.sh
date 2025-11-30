#!/usr/bin/env bash
set -euo pipefail

# ===== Tunables =====
: "${XRAY_PORT:=443}"
: "${XRAY_LISTEN:=[::]}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${XRAY_FALL:=127.0.0.1:9999}"
: "${XRAY_USER:=xray}"
: "${XRAY_GROUP:=xray}"

XRAY_STATE_DIR="/var/lib/xray"
XRAY_CONF_DIR="/etc/xray"
XRAY_CONF_FILE="${XRAY_CONF_DIR}/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="/etc/systemd/system/xray.service"

export DEBIAN_FRONTEND=noninteractive

# ===== Deps =====
apt update
apt install -y --no-install-recommends curl ca-certificates uuid-runtime unzip openssl

# ===== User & Dirs =====
getent group "$XRAY_GROUP" >/dev/null || groupadd --system "$XRAY_GROUP"
id -u "$XRAY_USER" >/dev/null 2>&1 || \
  useradd --system -g "$XRAY_GROUP" -M -d "$XRAY_STATE_DIR" -s /usr/sbin/nologin "$XRAY_USER"

install -d -o "$XRAY_USER" -g "$XRAY_GROUP" -m 750 "$XRAY_STATE_DIR"
install -d -o root        -g "$XRAY_GROUP" -m 750 "$XRAY_CONF_DIR"

# ===== Resolve latest tag via redirect (no API / no jq) =====
get_latest_tag() {
  local final
  final="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
           https://github.com/XTLS/Xray-core/releases/latest)" || return 1
  printf '%s\n' "${final##*/}"
}

echo "[*] Query latest Xray release (no-API)..."
tag="$(get_latest_tag)" || { echo "Failed to resolve latest tag"; exit 1; }

case "$(uname -m)" in
  x86_64|amd64)  MACHINE="64" ;;
  aarch64|arm64) MACHINE="arm64-v8a" ;;
  *) echo "Unsupported arch: $(uname -m) (x86_64/aarch64 only)" >&2; exit 1 ;;
esac

asset_name="Xray-linux-${MACHINE}.zip"
dl_url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset_name}"
echo "[*] Install version: ${tag}"
echo "[*] Asset:          ${asset_name}"

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
dl_file="${tmpd}/${asset_name}"
curl -fL "$dl_url" -o "$dl_file"

# ===== Extract & install =====
udir="${tmpd}/u"; mkdir -p "$udir"
unzip -q "$dl_file" -d "$udir"
binpath="$(find "$udir" -maxdepth 2 -type f -name 'xray' -perm -u+x | head -n1 || true)"
[ -n "$binpath" ] || { echo "xray binary not found in asset: $asset_name"; exit 1; }
install -m 0755 "$binpath" "$XRAY_BIN"

# ===== First-time config (idempotent) =====
if [ ! -f "$XRAY_CONF_FILE" ]; then
  XRAY_UUID="${XRAY_UUID:-$(uuidgen)}"

  cat >"$XRAY_CONF_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "${XRAY_LISTEN}",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": "${XRAY_FALL}",
            "xver": 2
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "rejectUnknownSni": true,
          "minVersion": "1.2",
          "alpn": [
            "h2",
            "http/1.1"
          ],
          "certificates": [
            {
              "ocspStapling": 3600,
              "certificateFile": "${CERT}",
              "keyFile": "${KEY}"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF

  chown root:"$XRAY_GROUP" "$XRAY_CONF_FILE"
  chmod 640 "$XRAY_CONF_FILE"
fi

# ===== systemd unit (create-once) =====
if [ ! -f "$XRAY_SERVICE" ]; then
  cat >"$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray Server (VLESS+TCP+XTLS-Vision)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${XRAY_USER}
Group=${XRAY_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${XRAY_STATE_DIR}
ExecStart=${XRAY_BIN} run -c ${XRAY_CONF_FILE}
Restart=on-failure
RestartSec=3s
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$XRAY_SERVICE"
fi

# ===== Start / Reload =====
systemctl daemon-reload
if systemctl is-enabled xray >/dev/null 2>&1; then
  systemctl try-reload-or-restart xray || systemctl restart xray
else
  systemctl enable --now xray || true
fi
