#!/usr/bin/env bash
set -euo pipefail

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${USERNAME:=}"
: "${PASS:=}"
: "${NAIVE_TAG:=}"
: "${LISTEN:=[::]:443}"
: "${FALLBACK:=[::1]:9999}"

APP_USER="naive"
APP_GROUP="naive"
APP_STATE_DIR="/var/lib/naive"
APP_CONF_DIR="/etc/naive"
APP_CONF_FILE="${APP_CONF_DIR}/config.json"
APP_BIN="/usr/local/bin/naive"
APP_SERVICE_NAME="naive"
APP_SERVICE="/etc/systemd/system/${APP_SERVICE_NAME}.service"
APP_REPO="sealszzz/Rules"
APP_ASSET_BASENAME="naive"
APP_BIN_NAME="naive"

export DEBIAN_FRONTEND=noninteractive

[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root" >&2; exit 1; }

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates tar xz-utils openssl jq

[ -r "$CERT" ] || { echo "FATAL: missing $CERT" >&2; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY" >&2; exit 1; }

getent group "$APP_GROUP" >/dev/null || groupadd --system "$APP_GROUP"
id -u "$APP_USER" >/dev/null 2>&1 || useradd --system -g "$APP_GROUP" -M -d "$APP_STATE_DIR" -s /usr/sbin/nologin "$APP_USER"

install -d -o "$APP_USER" -g "$APP_GROUP" -m 750 "$APP_STATE_DIR"
install -d -o root -g "$APP_GROUP" -m 750 "$APP_CONF_DIR"

chgrp "$APP_GROUP" "$CERT" "$KEY"
chmod 640 "$CERT" "$KEY"

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
    first(
      .assets[]?
      | select(.name | startswith($prefix) and endswith(".tar.gz"))
      | "\(.name)\t\(.browser_download_url)"
    ) // empty
  '
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

gen_pass() {
  openssl rand -hex 16
}

gen_user() {
  printf 'naive%s\n' "$(openssl rand -hex 3)"
}

if [ -z "$NAIVE_TAG" ]; then
  NAIVE_TAG="$(find_release_tag_for_asset "$APP_REPO" "${APP_ASSET_BASENAME}-${ASSET_ARCH}-")"
fi

[ -n "$NAIVE_TAG" ] || {
  echo "FATAL: failed to find a naive release for ${ASSET_ARCH}" >&2
  exit 1
}

install_release_asset "$APP_REPO" "$NAIVE_TAG" "$APP_ASSET_BASENAME" "$APP_BIN_NAME"

command -v "$APP_BIN" >/dev/null 2>&1 || { echo "FATAL: ${APP_BIN} not found" >&2; exit 1; }

if [ ! -f "$APP_CONF_FILE" ]; then
  [ -n "$USERNAME" ] || USERNAME="$(gen_user)"
  [ -n "$PASS" ] || PASS="$(gen_pass)"

  cat >"$APP_CONF_FILE" <<EOF_CONF
{
  "log_level": "info",
  "listen": "${LISTEN}",
  "users": [
    {
      "username": "${USERNAME}",
      "password": "${PASS}"
    }
  ],
  "tls": {
    "certificate": "${CERT}",
    "private_key": "${KEY}"
  },
  "proxy_protocol": false,
  "ipv6_relay": false,
  "dns": {
    "upstreams": [
      "1.1.1.1:53",
      "8.8.8.8:53"
    ],
    "cache_ttl_secs": 120,
    "query_timeout_ms": 1500
  },
  "tcp_keepalive_idle_secs": 60,
  "tcp_keepalive_interval_secs": 30,
  "fallback": {
    "address": "${FALLBACK}",
    "tls": true,
    "proxy_protocol": true,
    "tls_skip_verify": true
  }
}
EOF_CONF

  jq empty "$APP_CONF_FILE" >/dev/null 2>&1 || {
    echo "FATAL: invalid json generated" >&2
    cat "$APP_CONF_FILE" >&2
    exit 1
  }

  chown root:"$APP_GROUP" "$APP_CONF_FILE"
  chmod 640 "$APP_CONF_FILE"
fi

chown -R root:"$APP_GROUP" "$APP_CONF_DIR"
chmod 750 "$APP_CONF_DIR"
chmod 640 "$APP_CONF_FILE" || true

if [ ! -f "$APP_SERVICE" ]; then
  cat >"$APP_SERVICE" <<EOF_SERVICE
[Unit]
Description=Naive Rust Server
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

[Install]
WantedBy=multi-user.target
EOF_SERVICE

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

SHOW_USER=""
SHOW_PASS=""
SHOW_LISTEN=""
SHOW_FALLBACK=""

if [ -f "$APP_CONF_FILE" ]; then
  SHOW_USER="$(jq -r '.users[0].username // empty' "$APP_CONF_FILE" 2>/dev/null || true)"
  SHOW_PASS="$(jq -r '.users[0].password // empty' "$APP_CONF_FILE" 2>/dev/null || true)"
  SHOW_LISTEN="$(jq -r '.listen // empty' "$APP_CONF_FILE" 2>/dev/null || true)"
  SHOW_FALLBACK="$(jq -r '.fallback.address // empty' "$APP_CONF_FILE" 2>/dev/null || true)"
fi

echo
echo "app: naive"
echo "tag: ${NAIVE_TAG:-unknown}"
echo "bin: ${BIN_VER:-unknown}"
echo "config: ${APP_CONF_FILE}"
echo "listen: ${SHOW_LISTEN:-unknown}"
echo "fallback: ${SHOW_FALLBACK:-unknown}"
echo "username: ${SHOW_USER:-unknown}"
echo "password: ${SHOW_PASS:-unknown}"
