#!/usr/bin/env bash
# xray-min: install/upgrade Xray-core (VLESS+Vision+Reality), no geodata
# first run: create config + service; subsequent runs: upgrade binary only
set -euo pipefail

# ======= Tunables (change only if necessary) =======
: "${XRAY_PORT:=8888}"                       # loopback port for Nginx stream forwarding
: "${XRAY_SNI:=www.cloudflare.com}"          # Reality serverName (must exist in dest's cert)
: "${XRAY_DEST:=www.cloudflare.com:443}"     # Reality back-end (host:port)
: "${XRAY_USER:=xray}"
: "${XRAY_GROUP:=xray}"

XRAY_STATE_DIR="/var/lib/xray"
XRAY_CONF_DIR="/etc/xray"
XRAY_CONF_FILE="${XRAY_CONF_DIR}/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="/etc/systemd/system/xray.service"

export DEBIAN_FRONTEND=noninteractive

# ======= Dependencies (core only; no geodata) =======
apt update
apt install -y --no-install-recommends curl jq ca-certificates uuid-runtime unzip openssl

# ======= User & Directories =======
getent group "$XRAY_GROUP" >/dev/null || groupadd --system "$XRAY_GROUP"
id -u "$XRAY_USER" >/dev/null 2>&1 || \
  useradd --system -g "$XRAY_GROUP" -M -d "$XRAY_STATE_DIR" -s /usr/sbin/nologin "$XRAY_USER"

install -d -o "$XRAY_USER" -g "$XRAY_GROUP" -m 750 "$XRAY_STATE_DIR"
install -d -o root        -g "$XRAY_GROUP" -m 750 "$XRAY_CONF_DIR"

# ======= Fetch latest release & install binary =======
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)  MACHINE="64" ;;
  aarch64|arm64) MACHINE="arm64-v8a" ;;
  *) echo "Unsupported arch: $arch (x86_64/aarch64 only)">&2; exit 1 ;;
esac

echo "[*] Query latest Xray release..."
rel_json="$(curl -fsSL --retry 3 --retry-delay 1 https://api.github.com/repos/XTLS/Xray-core/releases/latest)"
[ -n "$rel_json" ] || { echo "Failed to get release info"; exit 1; }
tag="$(echo "$rel_json" | jq -r '.tag_name')"
[ -n "$tag" ] || { echo "Empty tag_name"; exit 1; }

zip_name="Xray-linux-${MACHINE}.zip"
dl_url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${zip_name}"
echo "[*] Install version: $tag"
echo "[*] Asset:          $zip_name"

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

curl -fL "$dl_url" -o "$tmpd/xray.zip"
unzip -q "$tmpd/xray.zip" -d "$tmpd/u"

binpath="$(find "$tmpd/u" -maxdepth 2 -type f -name 'xray' -perm -u+x | head -n1 || true)"
[ -n "$binpath" ] || { echo "xray binary not found in asset"; exit 1; }
install -m 0755 "$binpath" "$XRAY_BIN"

# ======= First-time config (idempotent; do not overwrite) =======
if [ ! -f "$XRAY_CONF_FILE" ]; then
  XRAY_UUID="${XRAY_UUID:-$(uuidgen)}"

  # ---- robust Reality key generation ----
  gen_reality_keys() {
    # 0) preset via env
    if [ -n "${XRAY_PRIV:-}" ] && [ -n "${XRAY_PUB:-}" ]; then return 0; fi

    # 1) typical xray x25519 output
    if out="$("$XRAY_BIN" x25519 2>/dev/null)"; then
      priv="$(printf '%s\n' "$out" | awk -F': *' '/^[Pp]rivate/{print $2; exit}')"
      pub="$( printf '%s\n' "$out" | awk -F': *' '/^[Pp]ublic/{print  $2; exit}')"
      if [ -n "$priv" ] && [ -n "$pub" ]; then XRAY_PRIV="$priv"; XRAY_PUB="$pub"; return 0; fi
    fi
    return 1
  }

  if ! gen_reality_keys; then
    cat >&2 <<'ERR'
[!] Failed to generate Reality keypair automatically.
    Please run:
      /usr/local/bin/xray x25519
    Then re-run this script with:
      XRAY_PRIV=<private> XRAY_PUB=<public> bash xray.sh
ERR
    exit 1
  fi

  XRAY_SHORTID="${XRAY_SHORTID:-$(openssl rand -hex 8)}"  # 8~16 hex; default 16 hex

  cat >"$XRAY_CONF_FILE" <<EOF
{
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          { "id": "${XRAY_UUID}", "flow": "xtls-rprx-vision" }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${XRAY_DEST}",
          "xver": 0,
          "serverNames": ["${XRAY_SNI}"],
          "privateKey": "${XRAY_PRIV}",
          "publicKey": "${XRAY_PUB}",
          "shortIds": ["${XRAY_SHORTID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom",  "tag": "direct"   },
    { "protocol": "blackhole","tag": "blocked"  }
  ]
}
EOF

  chown root:"$XRAY_GROUP" "$XRAY_CONF_FILE"
  chmod 640           "$XRAY_CONF_FILE"

  echo
  echo "==== Xray initial config created ===="
  echo "UUID:        $XRAY_UUID"
  echo "Reality PBK: $XRAY_PUB"
  echo "Reality PRK: $XRAY_PRIV"
  echo "ShortID:     $XRAY_SHORTID"
  echo "SNI:         $XRAY_SNI"
  echo "Dest:        $XRAY_DEST"
fi

# ======= systemd unit (create-once) =======
if [ ! -f "$XRAY_SERVICE" ]; then
  cat >"$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray (VLESS+Vision+Reality)
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

# ======= Start / Reload =======
systemctl daemon-reload
if systemctl is-enabled xray >/dev/null 2>&1; then
  systemctl try-reload-or-restart xray || systemctl restart xray
else
  systemctl enable --now xray || true
fi

# ======= Summary =======
echo
"$XRAY_BIN" -version 2>/dev/null || true
echo "Installed:  ${tag}"
echo "Config:     $XRAY_CONF_FILE"
echo "Binary:     $XRAY_BIN"
echo "Service:    $XRAY_SERVICE"
echo "Loopback listening (TCP ${XRAY_PORT}):"
ss -Hnplt | grep -E "127\.0\.0\.1:${XRAY_PORT}([^0-9]|$)" || echo "No local bind seen yet (just started?)"
