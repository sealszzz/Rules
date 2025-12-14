#!/usr/bin/env bash
# anytls-go minimal installer: install anytls-server + systemd (x86_64/aarch64)
set -euo pipefail

# ===== Tunables =====
: "${ANYTLS_PORT:=8443}"
: "${ANYTLS_LISTEN:=[::]}"
: "${ANYTLS_USER:=anytls}"
: "${ANYTLS_GROUP:=anytls}"
: "${ANYTLS_REPO:=anytls/anytls-go}"     # GitHub repo
: "${ANYTLS_TAG:=}"                      # override tag: v0.0.11 or 0.0.11, empty = latest
: "${ANYTLS_PASSWORD:=}"                # empty -> auto-generate

ANYTLS_STATE_DIR="/var/lib/anytls"
ANYTLS_BIN="/usr/local/bin/anytls-server"
ANYTLS_SERVICE="/etc/systemd/system/anytls.service"

export DEBIAN_FRONTEND=noninteractive

echo "[*] Install deps..."
apt update
apt install -y --no-install-recommends curl ca-certificates unzip openssl

# ===== User & Dirs =====
getent group "$ANYTLS_GROUP" >/dev/null || groupadd --system "$ANYTLS_GROUP"
id -u "$ANYTLS_USER" >/dev/null 2>&1 || \
  useradd --system -g "$ANYTLS_GROUP" -M -d "$ANYTLS_STATE_DIR" -s /usr/sbin/nologin "$ANYTLS_USER"

install -d -o "$ANYTLS_USER" -g "$ANYTLS_GROUP" -m 750 "$ANYTLS_STATE_DIR"

# ===== Resolve latest tag via redirect (no API / no jq) =====
get_latest_tag() {
  local final
  final="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
           "https://github.com/${ANYTLS_REPO}/releases/latest")" || return 1
  printf '%s\n' "${final##*/}"
}

if [ -n "${ANYTLS_TAG}" ]; then
  tag="$ANYTLS_TAG"  # 支持 v0.0.11 / 0.0.11
else
  echo "[*] Query latest AnyTLS release (no-API)..."
  tag="$(get_latest_tag)" || { echo "Failed to resolve latest tag"; exit 1; }
fi

# 规范化：tag 用 v0.0.11，version 用 0.0.11
case "$tag" in
  v*) version="${tag#v}" ;;
  *)  version="$tag"; tag="v${tag}" ;;
esac

case "$(uname -m)" in
  x86_64|amd64)  ANYTLS_OS="linux"; ANYTLS_ARCH="amd64" ;;
  aarch64|arm64) ANYTLS_OS="linux"; ANYTLS_ARCH="arm64" ;;
  *)
    echo "Unsupported arch: $(uname -m) (x86_64/aarch64 only)" >&2
    exit 1
    ;;
esac

asset_name="anytls_${version}_${ANYTLS_OS}_${ANYTLS_ARCH}.zip"
dl_url="https://github.com/${ANYTLS_REPO}/releases/download/${tag}/${asset_name}"

echo "[*] Install version: ${tag} (${version})"
echo "[*] Asset:           ${asset_name}"
echo "[*] URL:             ${dl_url}"

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
dl_file="${tmpd}/${asset_name}"
curl -fL "$dl_url" -o "$dl_file"

# ===== Extract & install =====
udir="${tmpd}/u"; mkdir -p "$udir"
unzip -q "$dl_file" -d "$udir"

# zip: readme.md / anytls-client / anytls-server，只装 server
binpath="$(find "$udir" -maxdepth 1 -type f -name 'anytls-server' -perm -u+x | head -n1 || true)"
[ -n "$binpath" ] || { echo "anytls-server binary not found in asset: $asset_name"; exit 1; }

echo "[*] Installing binary to ${ANYTLS_BIN}"
install -m 0755 "$binpath" "$ANYTLS_BIN"

# ===== Password (generate once if empty and service not exists) =====
if [ -z "${ANYTLS_PASSWORD}" ]; then
  if [ -f "$ANYTLS_SERVICE" ]; then
    # 已有 service，不动旧密码
    echo "[*] Service already exists, keep existing password in unit."
  else
    ANYTLS_PASSWORD="$(openssl rand -hex 16 || echo '0123456789abcdef0123456789abcdef')"
    echo "[*] Generated AnyTLS password: ${ANYTLS_PASSWORD}"
  fi
else
  echo "[*] Using provided ANYTLS_PASSWORD (env)."
fi

# ===== systemd unit (create-once) =====
if [ ! -f "$ANYTLS_SERVICE" ]; then
  echo "[*] Creating systemd unit: ${ANYTLS_SERVICE}"
  cat >"$ANYTLS_SERVICE" <<EOF
[Unit]
Description=AnyTLS Server
Documentation=https://github.com/${ANYTLS_REPO}
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${ANYTLS_USER}
Group=${ANYTLS_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${ANYTLS_STATE_DIR}
ExecStart=${ANYTLS_BIN} -l ${ANYTLS_LISTEN}:${ANYTLS_PORT} -p ${ANYTLS_PASSWORD}
Restart=on-failure
RestartSec=3s
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$ANYTLS_SERVICE"
else
  echo "[*] systemd unit already exists, skip writing: ${ANYTLS_SERVICE}"
fi

# ===== Start / Reload =====
echo "[*] Reload systemd & start service..."
systemctl daemon-reload
systemctl enable anytls
systemctl restart anytls

echo "[*] Done."
echo "    Port:     ${ANYTLS_PORT}"
echo "    Listen:   ${ANYTLS_LISTEN}"
[ -n "${ANYTLS_PASSWORD}" ] && echo "    Password: ${ANYTLS_PASSWORD}"
echo "Check status: systemctl status anytls --no-pager -l"
