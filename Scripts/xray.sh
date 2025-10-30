#!/usr/bin/env bash
# xray-min reset: VLESS+Vision+Reality, idempotent, loopback-by-default, no retries
set -euo pipefail

# ===== Tunables =====
: "${XRAY_PORT:=8888}"                         # default for Nginx stream -> 127.0.0.1:8888
: "${XRAY_LISTEN:=127.0.0.1}"                  # set to 0.0.0.0 for public listen when not using Nginx
: "${XRAY_SNI:=www.cloudflare.com}"            # must exist in dest's cert
: "${XRAY_DEST:=www.cloudflare.com:443}"       # upstream TLS endpoint
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
apt install -y --no-install-recommends curl jq ca-certificates uuid-runtime unzip openssl

# ===== User & Dirs =====
getent group "$XRAY_GROUP" >/dev/null || groupadd --system "$XRAY_GROUP"
id -u "$XRAY_USER" >/dev/null 2>&1 || \
  useradd --system -g "$XRAY_GROUP" -M -d "$XRAY_STATE_DIR" -s /usr/sbin/nologin "$XRAY_USER"

install -d -o "$XRAY_USER" -g "$XRAY_GROUP" -m 750 "$XRAY_STATE_DIR"
install -d -o root        -g "$XRAY_GROUP" -m 750 "$XRAY_CONF_DIR"

# ===== Fetch latest release & install binary =====
case "$(uname -m)" in
  x86_64|amd64)  MACHINE="64" ;;
  aarch64|arm64) MACHINE="arm64-v8a" ;;
  *) echo "Unsupported arch: $(uname -m) (x86_64/aarch64 only)">&2; exit 1 ;;
esac

echo "[*] Query latest Xray release..."
rel_json="$(curl -fsSL --retry 3 --retry-delay 1 https://api.github.com/repos/XTLS/Xray-core/releases/latest)" \
  || { echo "Failed to query release info"; exit 1; }
tag="$(echo "$rel_json" | jq -r '.tag_name')"
[ -n "$tag" ] || { echo "Empty tag_name"; exit 1; }

zip_name="Xray-linux-${MACHINE}.zip"
dl_url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${zip_name}"
echo "[*] Install version: $tag"
echo "[*] Asset:          $zip_name"

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
curl -fL "$dl_url" -o "$tmpd/xray.zip"
unzip -q "$tmpd/xray.zip" -d "$tmpd/u"
binpath="$(find "$tmpd/u" -maxdepth 2 -type f -name 'xray' -perm -u+x | head -n1 || true)"
[ -n "$binpath" ] || { echo "xray binary not found in asset"; exit 1; }
install -m 0755 "$binpath" "$XRAY_BIN"

# ===== Reality keypair (single-shot parse; fail fast) =====
# Accept preset XRAY_PRIV/XRAY_PUB; else parse xray x25519 output once.
parse_reality_keys() {
  if [ -n "${XRAY_PRIV:-}" ] && [ -n "${XRAY_PUB:-}" ]; then return 0; fi

  # normalize output: strip CR & ANSI
  local out; out="$("$XRAY_BIN" x25519 2>/dev/null | tr -d '\r' | sed 's/\x1B\[[0-9;]*[A-Za-z]//g')" || out=""

  # extract fields after colon (robust to extra spaces)
  local priv pub
  priv="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /^ *private ?key *$/ {gsub(/^ +| +$/,"",$2); print $2; exit}')"
  # public may appear as "PublicKey:" or (in some builds) "Password:"
  pub="$( printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /^ *public ?key *$/  {gsub(/^ +| +$/,"",$2); print $2; exit}')"
  if [ -z "$pub" ]; then
    pub="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /^ *password *$/     {gsub(/^ +| +$/,"",$2); print $2; exit}')"
  fi

  # quick sanity (base64url-ish; lengths vary by build,放宽到>=40)
  case "$priv" in ""|*[!A-Za-z0-9_-]*) priv="";; *) [ ${#priv} -lt 40 ] && priv="";; esac
  case "$pub"  in ""|*[!A-Za-z0-9_-]*)  pub="";;  *) [ ${#pub}  -lt 40 ] &&  pub="";; esac

  if [ -n "$priv" ] && [ -n "$pub" ]; then
    XRAY_PRIV="$priv"; XRAY_PUB="$pub"; return 0
  fi

  echo "[FATAL] cannot parse 'xray x25519' output; abort." >&2
  echo "-------- raw begin --------" >&2; printf '%s\n' "$out" >&2; echo "--------- raw end ---------" >&2
  return 1
}

# ===== First-time config (idempotent) =====
if [ ! -f "$XRAY_CONF_FILE" ]; then
  XRAY_UUID="${XRAY_UUID:-$(uuidgen)}"
  parse_reality_keys   # 失败就退出（set -e 生效）
  XRAY_SHORTID="${XRAY_SHORTID:-$(openssl rand -hex 8)}"   # 8~16 hex (默认给 16 hex)

  cat >"$XRAY_CONF_FILE" <<EOF
{
  "inbounds": [
    {
      "listen": "${XRAY_LISTEN}",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [ { "id": "${XRAY_UUID}", "flow": "xtls-rprx-vision" } ]
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
    { "protocol": "freedom",  "tag": "direct" },
    { "protocol": "blackhole","tag": "blocked" }
  ]
}
EOF
  chown root:"$XRAY_GROUP" "$XRAY_CONF_FILE"
  chmod 640 "$XRAY_CONF_FILE"

  echo "==== Xray initial config created ===="
  echo "UUID:        $XRAY_UUID"
  echo "Reality PBK: $XRAY_PUB"
  echo "Reality PRK: $XRAY_PRIV"
  echo "ShortID:     $XRAY_SHORTID"
  echo "Listen:      ${XRAY_LISTEN}:${XRAY_PORT}"
  echo "SNI/Dest:    ${XRAY_SNI} / ${XRAY_DEST}"
fi

# ===== systemd unit (create-once) =====
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

# ===== Start / Reload =====
systemctl daemon-reload
if systemctl is-enabled xray >/dev/null 2>&1; then
  systemctl try-reload-or-restart xray || systemctl restart xray
else
  systemctl enable --now xray || true
fi

# ===== Summary =====
"$XRAY_BIN" -version 2>/dev/null || true
echo "Installed:  ${tag}"
echo "Config:     $XRAY_CONF_FILE"
echo "Binary:     $XRAY_BIN"
echo "Service:    $XRAY_SERVICE"
echo "Listening:  ${XRAY_LISTEN}:${XRAY_PORT}"
