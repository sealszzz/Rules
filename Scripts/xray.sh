#!/usr/bin/env bash
# xray-min: install/upgrade Xray-core (VLESS+Vision+Reality), no geodata
# first run -> create config+service; subsequent runs -> upgrade binary only
set -euo pipefail

# ===== Tunables =====
: "${XRAY_PORT:=8888}"                       # loopback port for nginx stream
: "${XRAY_SNI:=www.cloudflare.com}"          # must exist in dest's cert
: "${XRAY_DEST:=www.cloudflare.com:443}"     # TLS 1.3 site or 1.1.1.1:443
: "${XRAY_USER:=xray}"
: "${XRAY_GROUP:=xray}"

XRAY_STATE_DIR="/var/lib/xray"
XRAY_CONF_DIR="/etc/xray"
XRAY_CONF_FILE="$XRAY_CONF_DIR/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="/etc/systemd/system/xray.service"

export DEBIAN_FRONTEND=noninteractive

# ===== Deps (no geodata) =====
apt update
apt install -y --no-install-recommends curl jq ca-certificates uuid-runtime unzip openssl

# ===== User & dirs =====
getent group "$XRAY_GROUP" >/dev/null || groupadd --system "$XRAY_GROUP"
id -u "$XRAY_USER" >/dev/null 2>&1 || useradd --system -g "$XRAY_GROUP" -M -d "$XRAY_STATE_DIR" -s /usr/sbin/nologin "$XRAY_USER"
install -d -o "$XRAY_USER" -g "$XRAY_GROUP" -m 750 "$XRAY_STATE_DIR"
install -d -o root        -g "$XRAY_GROUP" -m 750 "$XRAY_CONF_DIR"

# ===== Fetch latest Xray & install =====
case "$(uname -m)" in
  x86_64|amd64)  MACHINE="64" ;;
  aarch64|arm64) MACHINE="arm64-v8a" ;;
  *) echo "Unsupported arch"; exit 1 ;;
esac

echo "[*] Query latest Xray release..."
rel_json="$(curl -fsSL --retry 3 --retry-delay 1 https://api.github.com/repos/XTLS/Xray-core/releases/latest)"
tag="$(echo "$rel_json" | jq -r '.tag_name')"
[ -n "$tag" ] || { echo "Empty tag_name"; exit 1; }
zip_name="Xray-linux-${MACHINE}.zip"
dl_url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${zip_name}"
echo "[*] Install version: $tag"
echo "[*] Asset:          $zip_name"

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
curl -fL "$dl_url" -o "$tmpd/xray.zip"
unzip -q "$tmpd/xray.zip" -d "$tmpd/u"
binpath="$(find "$tmpd/u" -maxdepth 2 -type f -name xray -perm -u+x | head -n1 || true)"
[ -n "$binpath" ] || { echo "xray binary not found in asset"; exit 1; }
install -m 0755 "$binpath" "$XRAY_BIN"

# ===== First-time config (idempotent) =====
if [ ! -f "$XRAY_CONF_FILE" ]; then
  XRAY_UUID="${XRAY_UUID:-$(uuidgen)}"

  # ---- Reality keys: robust parse; fail-fast, no loops ----
  gen_reality_keys() {
    # allow manual injection
    if [ -n "${XRAY_PRIV:-}" ] && [ -n "${XRAY_PUB:-}" ]; then return 0; fi

    # run and scrub control codes / CRs
    local out priv pub
    out="$("$XRAY_BIN" x25519 2>/dev/null | tr -d '\r' | sed 's/\x1B\[[0-9;]*[A-Za-z]//g')" || true

    # accept "Private key:" or "PrivateKey:" (case/space tolerant)
    priv="$(printf '%s\n' "$out" \
      | awk -F':' 'tolower($1) ~ /^ *private ?key *$/ {gsub(/^ +| +$/,"",$2); print $2; exit}')"
    pub="$(printf '%s\n' "$out" \
      | awk -F':' 'tolower($1) ~ /^ *public ?key *$/  {gsub(/^ +| +$/,"",$2); print $2; exit}')"

    if [ -n "$priv" ] && [ -n "$pub" ]; then XRAY_PRIV="$priv"; XRAY_PUB="$pub"; return 0; fi

    echo "[FATAL] cannot parse xray x25519 output:" >&2
    echo "-------- raw begin --------" >&2
    printf '%s\n' "$out" >&2
    echo "--------- raw end ---------" >&2
    return 1
  }
  # ---- 强健的 Reality 密钥生成（无“兜底”，解析不到就硬失败）----
# ---- 强健的 Reality 密钥生成（解析不到就直接失败）----
gen_reality_keys() {
  # 允许通过环境变量注入
  if [ -n "${XRAY_PRIV:-}" ] && [ -n "${XRAY_PUB:-}" ]; then
    return 0
  fi

  # 运行并清理颜色/回车
  local out priv pub
  out="$("$XRAY_BIN" x25519 2>/dev/null | tr -d '\r' | sed 's/\x1B\[[0-9;]*[A-Za-z]//g')" || true

  # 兼容标签：PrivateKey / PublicKey / Password（有些构建把公钥写成 Password）
  priv="$(printf '%s\n' "$out" \
          | awk -F':' 'tolower($1) ~ /^ *private ?key *$/ {gsub(/^ +| +$/,"",$2); print $2; exit}')"
  pub="$( printf '%s\n' "$out" \
          | awk -F':' 'tolower($1) ~ /^ *public ?key *$/  {gsub(/^ +| +$/,"",$2); print $2; exit}')"
  if [ -z "$pub" ]; then
    pub="$(printf '%s\n' "$out" \
          | awk -F':' 'tolower($1) ~ /^ *password *$/     {gsub(/^ +| +$/,"",$2); print $2; exit}')"
  fi

  # 粗校验（Reality 用 base64url，通常 40+）
  case "$priv" in ""|*[!A-Za-z0-9_-]*) priv="";; *) [ ${#priv} -lt 40 ] && priv="";; esac
  case "$pub"  in ""|*[!A-Za-z0-9_-]*)  pub="";;  *) [ ${#pub}  -lt 40 ] &&  pub="";; esac

  if [ -n "$priv" ] && [ -n "$pub" ]; then
    XRAY_PRIV="$priv"
    XRAY_PUB="$pub"
    return 0
  fi

  echo "[FATAL] cannot parse xray x25519 output:" >&2
  echo "-------- raw begin --------" >&2
  printf '%s\n' "$out" >&2
  echo "--------- raw end ---------" >&2
  exit 1
}
  "outbounds": [
    { "protocol": "freedom",  "tag": "direct" },
    { "protocol": "blackhole","tag": "blocked" }
  ]
}
EOF
  chown root:"$XRAY_GROUP" "$XRAY_CONF_FILE"
  chmod 640 "$XRAY_CONF_FILE"

  echo "UUID: $XRAY_UUID"
  echo "PBK : $XRAY_PUB"
  echo "PRK : $XRAY_PRIV"
  echo "SID : $XRAY_SHORTID"
fi

# ===== systemd (create once) =====
# ========= systemd service（只在第一次创建）=========
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
echo
"$XRAY_BIN" -version 2>/dev/null || "$XRAY_BIN" version 2>/dev/null || true
echo "Installed:  ${tag}"
echo "Config:     $XRAY_CONF_FILE"
echo "Binary:     $XRAY_BIN"
echo "Service:    $XRAY_SERVICE"
echo "Loopback:   127.0.0.1:${XRAY_PORT}"
