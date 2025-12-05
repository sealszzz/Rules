#!/usr/bin/env bash
# anytls-min: install anytls-server binary with systemd unit (x86_64/aarch64)
set -euo pipefail

# ===== Tunables =====
: "${ANYTLS_PORT:=8443}"
: "${ANYTLS_LISTEN:=[::]}"
: "${ANYTLS_USER:=anytls}"
: "${ANYTLS_GROUP:=anytls}"
: "${ANYTLS_REPO:=anytls/anytls-go}"         # GitHub repo
: "${ANYTLS_TAG:=}"                          # override tag like v0.0.11 (empty = latest)

ANYTLS_STATE_DIR="/var/lib/anytls"
ANYTLS_CONF_DIR="/etc/anytls"
ANYTLS_ENV_FILE="${ANYTLS_CONF_DIR}/anytls.env"

ANYTLS_BIN="/usr/local/bin/anytls-server"
ANYTLS_SERVICE="/etc/systemd/system/anytls.service"

export DEBIAN_FRONTEND=noninteractive

# ===== Deps =====
apt update
apt install -y --no-install-recommends curl ca-certificates unzip openssl

# ===== User & Dirs =====
getent group "$ANYTLS_GROUP" >/dev/null || groupadd --system "$ANYTLS_GROUP"
id -u "$ANYTLS_USER" >/dev/null 2>&1 || \
  useradd --system -g "$ANYTLS_GROUP" -M -d "$ANYTLS_STATE_DIR" -s /usr/sbin/nologin "$ANYTLS_USER"

install -d -o "$ANYTLS_USER"  -g "$ANYTLS_GROUP" -m 750 "$ANYTLS_STATE_DIR"
install -d -o root            -g "$ANYTLS_GROUP" -m 750 "$ANYTLS_CONF_DIR"

# ===== Resolve latest tag via redirect (no API / no jq) =====
get_latest_tag() {
  local final
  final="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
           "https://github.com/${ANYTLS_REPO}/releases/latest")" || return 1
  printf '%s\n' "${final##*/}"
}

if [ -n "${ANYTLS_TAG}" ]; then
  tag="$ANYTLS_TAG"
else
  echo "[*] Query latest AnyTLS release (no-API)..."
  tag="$(get_latest_tag)" || { echo "Failed to resolve latest tag"; exit 1; }
fi

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

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
dl_file="${tmpd}/${asset_name}"
curl -fL "$dl_url" -o "$dl_file"

# ===== Extract & install =====
udir="${tmpd}/u"; mkdir -p "$udir"
unzip -q "$dl_file" -d "$udir"

binpath="$(find "$udir" -maxdepth 1 -type f -name 'anytls-server' -perm -u+x | head -n1 || true)"
[ -n "$binpath" ] || { echo "anytls-server binary not found in asset: $asset_name"; exit 1; }

install -m 0755 "$binpath" "$ANYTLS_BIN"

# ===== Env file (create-once, idempotent) =====
if [ -f "$ANYTLS_ENV_FILE" ]; then
  # reuse existing values
  # shellcheck disable=SC1090
  . "$ANYTLS_ENV_FILE"
else
  : "${ANYTLS_PASSWORD:=$(openssl rand -hex 16 || echo '0123456789abcdef0123456789abcdef')}"
  cat >"$ANYTLS_ENV_FILE" <<EOF
ANYTLS_LISTEN=${ANYTLS_LISTEN}
ANYTLS_PORT=${ANYTLS_PORT}
ANYTLS_PASSWORD=${ANYTLS_PASSWORD}
EOF
  chown root:"$ANYTLS_GROUP" "$ANYTLS_ENV_FILE"
  chmod 640 "$ANYTLS_ENV_FILE"

  echo "[*] AnyTLS password (also saved in ${ANYTLS_ENV_FILE}):"
  echo "    ${ANYTLS_PASSWORD}"
fi

# ===== systemd unit (create-once) =====
if [ ! -f "$ANYTLS_SERVICE" ]; then
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
EnvironmentFile=${ANYTLS_ENV_FILE}
ExecStart=${ANYTLS_BIN} -l \$ANYTLS_LISTEN:\$ANYTLS_PORT -p \$ANYTLS_PASSWORD
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
fi

# ===== Start / Reload =====
systemctl daemon-reload
if systemctl is-enabled anytls >/dev/null 2>&1; then
  systemctl try-reload-or-restart anytls || systemctl restart anytls
else
  systemctl enable --now anytls || true
fi
