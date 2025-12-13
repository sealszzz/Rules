#!/usr/bin/env bash
# caddy-l4 TCP+UDP 443 SNI STREAM (admin disabled, no home dir)
set -euo pipefail

: "${ANYTLS_PORT:=8001}"
: "${VLESS_PORT:=8002}"
: "${ANYTLS_SNI:=anytls.example.com}"

: "${TUIC_PORT:=9001}"
: "${JUICITY_PORT:=9002}"
: "${TUIC_SNI:=tuic.example.com}"
: "${JUICITY_SNI:=juicity.example.com}"

: "${CADDY_USER:=caddy}"
: "${CADDY_GROUP:=caddy}"
: "${CADDY_BIN:=/usr/local/bin/caddy-l4}"
: "${CADDY_CONF:=/etc/caddy/caddy.json}"
: "${CADDY_SERVICE:=/etc/systemd/system/caddy-l4.service}"
: "${CADDY_REPO:=sealszzz/Caddy}"

# optional: force rewrite
: "${CADDY_FORCE_CONF:=0}"   # 1 = overwrite config even if exists
: "${CADDY_FORCE_UNIT:=0}"   # 1 = overwrite systemd unit even if exists

CADDY_SERVICE_NAME="caddy-l4"
CADDY_STATE_DIR="/var/lib/caddy-l4"

export DEBIAN_FRONTEND=noninteractive

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "FATAL: run as root" >&2; exit 1; }; }
need_root

apt-get update >/dev/null
apt-get install -y --no-install-recommends curl ca-certificates tar coreutils findutils grep sed >/dev/null

detect_arch() {
  case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    amd64|x86_64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *)
      echo "FATAL: unsupported arch: $(uname -m)" >&2
      exit 1
      ;;
  esac
}
ARCH="$(detect_arch)"

get_latest_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${CADDY_REPO}/releases/latest")" || return 1
  printf '%s\n' "${u##*/}"
}

TAG="$(get_latest_tag)" || { echo "FATAL: failed to resolve latest tag" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

asset_url_guess="https://github.com/${CADDY_REPO}/releases/download/${TAG}/caddy-l4-linux-${ARCH}-${TAG}.tar.gz"

# If guessed URL fails, scrape release HTML for a matching tarball link.
resolve_asset_url() {
  local url="$1"
  if curl -fsSI "$url" >/dev/null 2>&1; then
    printf '%s\n' "$url"
    return 0
  fi

  # scrape release page html, match download href for linux-${ARCH} tar.gz (tag optional in name)
  local rel_html href
  rel_html="$(curl -fsSL "https://github.com/${CADDY_REPO}/releases/tag/${TAG}")" || return 1

  # try strict: contains "caddy-l4-linux-${ARCH}" and ends with ".tar.gz"
  href="$(printf '%s' "$rel_html" \
    | grep -Eo "/${CADDY_REPO}/releases/download/${TAG}/caddy-l4-linux-${ARCH}[^\"']*\.tar\.gz" \
    | head -n1 || true)"

  [ -n "$href" ] || return 1
  printf 'https://github.com%s\n' "$href"
}

ASSET_URL="$(resolve_asset_url "$asset_url_guess")" || {
  echo "FATAL: cannot find a matching asset for arch=${ARCH} tag=${TAG}" >&2
  exit 1
}

ASSET_NAME="${ASSET_URL##*/}"

curl -fL --retry 3 --retry-delay 1 -o "$TMP_DIR/$ASSET_NAME" "$ASSET_URL"
tar -xzf "$TMP_DIR/$ASSET_NAME" -C "$TMP_DIR"

# locate installed binary inside tar output
BIN_SRC="$(find "$TMP_DIR" -maxdepth 3 -type f -name 'caddy*' -perm -u+x | head -n1 || true)"
[ -n "$BIN_SRC" ] || { echo "FATAL: extracted binary not found in tar" >&2; exit 1; }

install -m 0755 "$BIN_SRC" "$CADDY_BIN"

# user/group
getent group "$CADDY_GROUP" >/dev/null || groupadd --system "$CADDY_GROUP"
if ! id -u "$CADDY_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home \
    --gid "$CADDY_GROUP" \
    --shell /usr/sbin/nologin \
    "$CADDY_USER"
fi

# dirs
install -d -o root -g "$CADDY_GROUP" -m 750 /etc/caddy
install -d -o "$CADDY_USER" -g "$CADDY_GROUP" -m 750 "$CADDY_STATE_DIR"

# config (create-once by default)
if [ "$CADDY_FORCE_CONF" = "1" ] || [ ! -f "$CADDY_CONF" ]; then
  cat >"$CADDY_CONF" <<EOF
{
  "admin": { "disabled": true },
  "apps": {
    "layer4": {
      "servers": {
        "tcp443": {
          "listen": [":443"],
          "routes": [
            {
              "match": [
                { "tls": { "sni": ["${ANYTLS_SNI}"] } }
              ],
              "handle": [
                {
                  "handler": "proxy",
                  "upstreams": [
                    { "dial": ["tcp/127.0.0.1:${ANYTLS_PORT}"] }
                  ]
                }
              ]
            },
            {
              "match": [
                { "tls": {} }
              ],
              "handle": [
                {
                  "handler": "proxy",
                  "upstreams": [
                    { "dial": ["tcp/127.0.0.1:${VLESS_PORT}"] }
                  ]
                }
              ]
            }
          ]
        },
        "udp443": {
          "listen": ["udp/:443"],
          "routes": [
            {
              "match": [
                { "quic": { "sni": ["${TUIC_SNI}"] } }
              ],
              "handle": [
                {
                  "handler": "proxy",
                  "upstreams": [
                    { "dial": ["udp/127.0.0.1:${TUIC_PORT}"] }
                  ]
                }
              ]
            },
            {
              "match": [
                { "quic": { "sni": ["${JUICITY_SNI}"] } }
              ],
              "handle": [
                {
                  "handler": "proxy",
                  "upstreams": [
                    { "dial": ["udp/127.0.0.1:${JUICITY_PORT}"] }
                  ]
                }
              ]
            }
          ]
        }
      }
    }
  }
}
EOF
  chown root:"$CADDY_GROUP" "$CADDY_CONF"
  chmod 640 "$CADDY_CONF"
fi

# systemd (create-once by default)
if [ "$CADDY_FORCE_UNIT" = "1" ] || [ ! -f "$CADDY_SERVICE" ]; then
  cat >"$CADDY_SERVICE" <<EOF
[Unit]
Description=Caddy layer4 TCP+UDP 443 SNI proxy
After=network.target

[Service]
User=${CADDY_USER}
Group=${CADDY_GROUP}
Environment=HOME=${CADDY_STATE_DIR}
Environment=XDG_DATA_HOME=${CADDY_STATE_DIR}
Environment=XDG_CONFIG_HOME=/etc/caddy
WorkingDirectory=${CADDY_STATE_DIR}
ExecStart=${CADDY_BIN} run --config ${CADDY_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$CADDY_SERVICE"
fi

systemctl daemon-reload
systemctl enable "$CADDY_SERVICE_NAME" >/dev/null 2>&1 || true

if systemctl is-active --quiet "$CADDY_SERVICE_NAME"; then
  systemctl restart "$CADDY_SERVICE_NAME"
else
  systemctl start "$CADDY_SERVICE_NAME"
fi

echo "caddy-l4 updated to tag: ${TAG}"
echo "[*] caddy-l4 binary version:"
"$CADDY_BIN" version 2>/dev/null || "$CADDY_BIN" -version 2>/dev/null || "$CADDY_BIN" --version 2>/dev/null || true
