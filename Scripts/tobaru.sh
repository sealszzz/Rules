#!/usr/bin/env bash
set -euo pipefail

: "${TOBARU_TAG:=}"

APP_USER="tobaru"
APP_GROUP="tobaru"
APP_STATE_DIR="/var/lib/tobaru"
APP_CONF_DIR="/etc/tobaru"
APP_CONF_FILE="${APP_CONF_DIR}/tobaru.yml"
APP_BIN="/usr/local/bin/tobaru"
APP_SERVICE_NAME="tobaru"
APP_SERVICE="/etc/systemd/system/${APP_SERVICE_NAME}.service"
APP_REPO="sealszzz/Rules"
APP_ASSET_BASENAME="tobaru"
APP_BIN_NAME="tobaru"

export DEBIAN_FRONTEND=noninteractive

[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root" >&2; exit 1; }

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates tar jq

getent group "$APP_GROUP" >/dev/null || groupadd --system "$APP_GROUP"
id -u "$APP_USER" >/dev/null 2>&1 || useradd --system -g "$APP_GROUP" -M -d "$APP_STATE_DIR" -s /usr/sbin/nologin "$APP_USER"

install -d -o "$APP_USER" -g "$APP_GROUP" -m 750 "$APP_STATE_DIR"
install -d -o root -g "$APP_GROUP" -m 750 "$APP_CONF_DIR"

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
  amd64|x86_64)  ASSET_ARCH="linux-amd64" ;;
  arm64|aarch64) ASSET_ARCH="linux-arm64" ;;
  *) echo "FATAL: unsupported arch: $(dpkg --print-architecture 2>/dev/null || uname -m)" >&2; exit 1 ;;
esac

find_release_tag_for_asset() {
  local repo="$1"
  local prefix="$2"
  local api

  api="https://api.github.com/repos/${repo}/releases?per_page=100"

  curl -fsSL "$api" | jq -r --arg prefix "$prefix" '
    map(select(any(.assets[]?; (.name | startswith($prefix) and endswith(".tar.gz")))))
    | .[0].tag_name // empty
  '
}

find_asset_by_tag() {
  local repo="$1"
  local tag="$2"
  local prefix="$3"
  local api

  api="https://api.github.com/repos/${repo}/releases/tags/${tag}"

  curl -fsSL "$api" | jq -r --arg prefix "$prefix" '
    .assets[]?
    | select(.name | startswith($prefix) and endswith(".tar.gz"))
    | "\(.name)\t\(.browser_download_url)"
  ' | head -n1
}

install_release_asset() {
  local repo="$1"
  local tag="$2"
  local base_name="$3"
  local bin_name="$4"
  local prefix asset_line asset_name url tmpd bin

  prefix="${base_name}-${ASSET_ARCH}-"
  asset_line="$(find_asset_by_tag "$repo" "$tag" "$prefix")"

  [ -n "$asset_line" ] || {
    echo "FATAL: failed to find ${prefix}*.tar.gz in release tag ${tag}" >&2
    exit 1
  }

  asset_name="${asset_line%%$'\t'*}"
  url="${asset_line#*$'\t'}"

  [ -n "$asset_name" ] || { echo "FATAL: empty asset name" >&2; exit 1; }
  [ -n "$url" ] || { echo "FATAL: empty download url" >&2; exit 1; }

  echo "tag: ${tag}"
  echo "asset: ${asset_name}"
  echo "download: ${url}"

  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' RETURN

  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.tgz" "$url"
  mkdir -p "$tmpd/unpack"
  tar -xzf "$tmpd/pkg.tgz" -C "$tmpd/unpack"

  if [ -f "$tmpd/unpack/$bin_name" ]; then
    bin="$tmpd/unpack/$bin_name"
  else
    bin="$(find "$tmpd/unpack" -maxdepth 3 -type f -name "$bin_name" | head -n1 || true)"
  fi

  [ -n "${bin:-}" ] || { echo "FATAL: ${bin_name} binary not found" >&2; exit 1; }

  install -m 0755 "$bin" "$APP_BIN"

  rm -rf "$tmpd"
  trap - RETURN
}

if [ -z "$TOBARU_TAG" ]; then
  TOBARU_TAG="$(find_release_tag_for_asset "$APP_REPO" "${APP_ASSET_BASENAME}-${ASSET_ARCH}-")"
fi

[ -n "$TOBARU_TAG" ] || {
  echo "FATAL: failed to find a tobaru release for ${ASSET_ARCH}" >&2
  exit 1
}

install_release_asset "$APP_REPO" "$TOBARU_TAG" "$APP_ASSET_BASENAME" "$APP_BIN_NAME"

command -v "$APP_BIN" >/dev/null 2>&1 || { echo "FATAL: ${APP_BIN} not found" >&2; exit 1; }

if [ ! -f "$APP_CONF_FILE" ]; then
  cat >"$APP_CONF_FILE" <<'EOF'
logging:
  level: info

listeners:
  - address: "[::]:443"
    transport: tcp
    targets:
      - location: drop
        server_tls:
          sni_hostnames: [none, any]

      - location: "[::1]:9001"
        proxy_protocol: true
        server_tls:
          sni_hostnames:
            - example.com

      - location: "[::1]:9002"
        proxy_protocol: true
        server_tls:
          sni_hostnames:
            - www.example.com

      - location: "[::1]:9999"
        proxy_protocol: true
        server_tls:
          sni_hostnames:
            - "*.example.com"

      - location: "[::1]:9009"

  - address: "[::]:443"
    transport: udp
    targets:
      - location: drop
        server_quic:
          sni_hostnames: [none, any]

      - location: "[::1]:9001"
        server_quic:
          sni_hostnames:
            - example.com

      - location: "[::1]:9002"
        server_quic:
          sni_hostnames:
            - www.example.com

      - location: "[::1]:9999"
        server_quic:
          sni_hostnames:
            - "*.example.com"

      - location: "[::1]:9009"
EOF

  chown root:"$APP_GROUP" "$APP_CONF_FILE"
  chmod 640 "$APP_CONF_FILE"
fi

chown -R root:"$APP_GROUP" "$APP_CONF_DIR"
chmod 750 "$APP_CONF_DIR"
chmod 640 "$APP_CONF_FILE" || true

if [ ! -f "$APP_SERVICE" ]; then
  cat >"$APP_SERVICE" <<EOF
[Unit]
Description=tobaru TLS/QUIC SNI router
Documentation=https://github.com/${APP_REPO}/releases
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${APP_USER}
Group=${APP_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${APP_STATE_DIR}
ExecStart=${APP_BIN} ${APP_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s
SyslogIdentifier=${APP_SERVICE_NAME}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$APP_SERVICE"
fi

systemctl daemon-reload

if systemctl is-enabled --quiet "$APP_SERVICE_NAME"; then
  systemctl restart "$APP_SERVICE_NAME"
else
  systemctl enable --now "$APP_SERVICE_NAME"
fi

BIN_VER="$("$APP_BIN" --version 2>/dev/null || true)"
BIN_VER="$(printf '%s\n' "$BIN_VER" | head -n1)"

echo
echo "app: tobaru"
echo "tag: ${TOBARU_TAG:-unknown}"
echo "bin: ${BIN_VER:-unknown}"
echo "config: ${APP_CONF_FILE}"
systemctl --no-pager --full status "$APP_SERVICE_NAME" || true
