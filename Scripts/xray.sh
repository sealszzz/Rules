#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

: "${XRAY_LISTEN:=[::]}"
: "${XRAY_SNI:=www.cloudflare.com}"
: "${XRAY_TARGET:=127.0.0.1:9999}"
: "${XRAY_USER:=xray}"
: "${XRAY_GROUP:=xray}"
: "${XRAY_TAG:=}"

XRAY_STATE_DIR="/var/lib/xray"
XRAY_CONF_DIR="/etc/xray"
XRAY_CONF_FILE="${XRAY_CONF_DIR}/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="/etc/systemd/system/xray.service"
XRAY_SERVICE_NAME="xray"
XRAY_ASSET_DIR="/usr/local/share/xray"

apt-get update
apt-get install -y --no-install-recommends \
  curl ca-certificates uuid-runtime unzip openssl iproute2

getent group "$XRAY_GROUP" >/dev/null || groupadd --system "$XRAY_GROUP"
id -u "$XRAY_USER" >/dev/null 2>&1 || \
  useradd --system -g "$XRAY_GROUP" -M -d "$XRAY_STATE_DIR" -s /usr/sbin/nologin "$XRAY_USER"

install -d -o "$XRAY_USER" -g "$XRAY_GROUP" -m 750 "$XRAY_STATE_DIR"
install -d -o root        -g "$XRAY_GROUP" -m 750 "$XRAY_CONF_DIR"
install -d -o root        -g root         -m 755 "$XRAY_ASSET_DIR"

get_latest_tag() {
  if [ -n "${XRAY_TAG:-}" ]; then
    printf '%s\n' "$XRAY_TAG"
    return 0
  fi

  local final
  final="$(
    curl -fsSIL -o /dev/null -w '%{url_effective}' \
      "https://github.com/XTLS/Xray-core/releases/latest"
  )" || return 1

  printf '%s\n' "${final##*/}"
}

echo "[*] Query latest Xray release (no-API, via 302)…"
tag="$(get_latest_tag)" || { echo "Failed to resolve latest tag"; exit 1; }

case "$(uname -m)" in
  x86_64|amd64)  MACHINE="64"        ;;
  aarch64|arm64) MACHINE="arm64-v8a" ;;
  *)
    echo "Unsupported arch: $(uname -m)" >&2
    exit 1
    ;;
esac

asset_name="Xray-linux-${MACHINE}.zip"
dl_url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset_name}"

echo "[*] Install version: ${tag}"
echo "[*] Asset:          ${asset_name}"

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

dl_file="${tmpd}/${asset_name}"
curl -fL --retry 3 --retry-delay 1 -o "$dl_file" "$dl_url"

udir="${tmpd}/u"
mkdir -p "$udir"
unzip -q "$dl_file" -d "$udir"

binpath="$(find "$udir" -maxdepth 2 -type f -name 'xray' -perm -u+x | head -n1 || true)"
[ -n "$binpath" ] || { echo "xray binary not found in asset: $asset_name"; exit 1; }

install -m 0755 "$binpath" "$XRAY_BIN"

parse_reality_keys() {
  local out priv pub
  out="$("$XRAY_BIN" x25519 2>/dev/null | tr -d '\r')" || out=""

  priv="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /^ *private ?key *$/ {print $2; exit}')"
  pub="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /^ *password *$/    {print $2; exit}')"

  if [ -z "$priv" ] || [ -z "$pub" ]; then
    echo "[FATAL] cannot parse xray x25519 output" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi

  XRAY_PRIV="$priv"
  XRAY_PUB="$pub"
}

gen_vlessenc_native() {
  local out line
  out="$("$XRAY_BIN" vlessenc 2>/dev/null | tr -d '\r')" || out=""
  line="$(printf '%s\n' "$out" | awk 'NF{print; exit}')"

  if [ -z "$line" ] || ! printf '%s' "$line" | grep -q '\.native\.'; then
    echo "[FATAL] xray vlessenc failed or not native/raw output" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi

  printf '%s\n' "$line"
}

if [ ! -f "$XRAY_CONF_FILE" ]; then
  XRAY_UUID="$(uuidgen)"
  XRAY_SHORTID="$(openssl rand -hex 8)"
  parse_reality_keys
  XRAY_VLESSENC="$(gen_vlessenc_native)"

  cat >"$XRAY_CONF_FILE" <<EOF
{
  "inbounds": [
    {
      "listen": "[::]",
      "port": 4443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${XRAY_TARGET}",
          "xver": 0,
          "serverNames": [
            "${XRAY_SNI}"
          ],
          "privateKey": "${XRAY_PRIV}",
          "publicKey": "${XRAY_PUB}",
          "shortIds": [
            "${XRAY_SHORTID}"
          ]
        }
      }
    },
    {
      "listen": "[::]",
      "port": 5443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${XRAY_VLESSENC}",
        "encryption": "${XRAY_VLESSENC}"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "targetStrategy": "UseIPv4v6"
      }
    }
  ]
}
EOF

  chown root:"$XRAY_GROUP" "$XRAY_CONF_FILE"
  chmod 640 "$XRAY_CONF_FILE"
fi

if [ ! -f "$XRAY_SERVICE" ]; then
  cat >"$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray Server
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${XRAY_USER}
Group=${XRAY_GROUP}
Environment=XRAY_LOCATION_ASSET=${XRAY_ASSET_DIR}
Type=simple
UMask=0077
WorkingDirectory=${XRAY_STATE_DIR}
ExecStart=${XRAY_BIN} run -c ${XRAY_CONF_FILE}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$XRAY_SERVICE"
fi

systemctl daemon-reload
if systemctl is-enabled "$XRAY_SERVICE_NAME" >/dev/null 2>&1; then
  systemctl try-reload-or-restart "$XRAY_SERVICE_NAME" || systemctl restart "$XRAY_SERVICE_NAME"
else
  systemctl enable --now "$XRAY_SERVICE_NAME"
fi
