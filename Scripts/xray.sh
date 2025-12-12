#!/usr/bin/env bash
set -euo pipefail

# ===== Tunables =====
: "${XRAY_PORT:=443}"
: "${XRAY_LISTEN:=[::]}"
: "${XRAY_SNI:=www.cloudflare.com}"     # must exist in dest's cert
: "${XRAY_TARGET:=127.0.0.1:9999}"      # upstream TLS endpoint (Reality target)
: "${XRAY_DEST:=127.0.0.1:9999}"        # fallback dest
: "${XRAY_USER:=xray}"
: "${XRAY_GROUP:=xray}"
: "${XRAY_TAG:=}"

XRAY_STATE_DIR="/var/lib/xray"
XRAY_CONF_DIR="/etc/xray"
XRAY_CONF_FILE="${XRAY_CONF_DIR}/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="/etc/systemd/system/xray.service"

export DEBIAN_FRONTEND=noninteractive

# ===== Deps =====
apt update
apt install -y --no-install-recommends curl ca-certificates uuid-runtime unzip openssl iproute2

# ===== User & Dirs =====
getent group "$XRAY_GROUP" >/dev/null || groupadd --system "$XRAY_GROUP"
id -u "$XRAY_USER" >/dev/null 2>&1 || \
  useradd --system -g "$XRAY_GROUP" -M -d "$XRAY_STATE_DIR" -s /usr/sbin/nologin "$XRAY_USER"

install -d -o "$XRAY_USER" -g "$XRAY_GROUP" -m 750 "$XRAY_STATE_DIR"
install -d -o root        -g "$XRAY_GROUP" -m 750 "$XRAY_CONF_DIR"

# ===== Resolve release tag via /releases/latest 302 (no API / no HTML) =====
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
    echo "Unsupported arch: $(uname -m) (x86_64/aarch64 only)" >&2
    exit 1
    ;;
esac

asset_name="Xray-linux-${MACHINE}.zip"
dl_url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset_name}"

echo "[*] Install version: ${tag}"
echo "[*] Asset:          ${asset_name}"

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
dl_file="${tmpd}/${asset_name}"
curl -fL --retry 3 --retry-delay 1 -o "$dl_file" "$dl_url"

# ===== Extract & install =====
udir="${tmpd}/u"; mkdir -p "$udir"
unzip -q "$dl_file" -d "$udir"

binpath="$(find "$udir" -maxdepth 2 -type f -name 'xray' -perm -u+x | head -n1 || true)"
[ -n "$binpath" ] || { echo "xray binary not found in asset: $asset_name"; exit 1; }

install -m 0755 "$binpath" "$XRAY_BIN"

# ===== Reality keypair (single-shot parse; fail fast) =====
parse_reality_keys() {
  if [ -n "${XRAY_PRIV:-}" ] && [ -n "${XRAY_PUB:-}" ]; then
    return 0
  fi

  local out
  out="$("$XRAY_BIN" x25519 2>/dev/null | tr -d '\r' | sed 's/\x1B\[[0-9;]*[A-Za-z]//g')" || out=""

  local priv pub
  priv="$(
    printf '%s\n' "$out" \
      | awk -F': *' 'tolower($1) ~ /^ *private ?key *$/ {gsub(/^ +| +$/,"",$2); print $2; exit}'
  )"
  pub="$(
    printf '%s\n' "$out" \
      | awk -F': *' 'tolower($1) ~ /^ *public ?key *$/  {gsub(/^ +| +$/,"",$2); print $2; exit}'
  )"

  [ -z "$pub" ] && pub="$(
    printf '%s\n' "$out" \
      | awk -F': *' 'tolower($1) ~ /^ *password *$/ {gsub(/^ +| +$/,"",$2); print $2; exit}'
  )"

  case "$priv" in ""|*[!A-Za-z0-9_-]*) priv="";; *) [ ${#priv} -lt 40 ] && priv="";; esac
  case "$pub"  in ""|*[!A-Za-z0-9_-]*)  pub="";;  *) [ ${#pub}  -lt 40 ] &&  pub="";; esac

  if [ -n "$priv" ] && [ -n "$pub" ]; then
    XRAY_PRIV="$priv"
    XRAY_PUB="$pub"
    return 0
  fi

  echo "[FATAL] cannot parse 'xray x25519' output; abort." >&2
  echo "-------- raw begin --------" >&2
  printf '%s\n' "$out" >&2
  echo "--------- raw end ---------" >&2
  return 1
}

# ===== First-time config (idempotent) =====
if [ ! -f "$XRAY_CONF_FILE" ]; then
  XRAY_UUID="${XRAY_UUID:-$(uuidgen)}"
  XRAY_SHORTID="${XRAY_SHORTID:-$(openssl rand -hex 8)}"
  parse_reality_keys

  cat >"$XRAY_CONF_FILE" <<EOF
{
  "inbounds": [
    {
      "listen": "${XRAY_LISTEN}",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "fallbacks": [
          {
            "dest": "${XRAY_DEST}",
            "xver": 2
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${XRAY_TARGET}",
          "xver": 2,
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
Description=Xray Server
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

# ===== Start / Reload =====
systemctl daemon-reload
if systemctl is-enabled xray >/devnull 2>&1; then
  systemctl try-reload-or-restart xray || systemctl restart xray
else
  systemctl enable --now xray || true
fi
