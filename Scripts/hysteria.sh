#!/usr/bin/env bash
set -euo pipefail

: "${HY_PORT:=8443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${SNI_GUARD:=strict}"                 # strict | disable | dns-san
: "${OBFS_PASS:=}"                       # empty => auto-generate
: "${AUTH_PASS:=}"                       # empty => auto-generate
: "${DIRECT_MODE:=46}"                   # auto | 64 | 46 | 6 | 4
: "${FASTOPEN:=false}"

HY_USER="hysteria"
HY_GROUP="hysteria"

HY_STATE_DIR="/var/lib/hysteria"
HY_ETC_DIR="/etc/hysteria"
HY_CONF="${HY_ETC_DIR}/config.yaml"

HY_BIN="/usr/local/bin/hysteria"
HY_SVC_NAME="hysteria"
HY_SVC="/etc/systemd/system/${HY_SVC_NAME}.service"

export DEBIAN_FRONTEND=noninteractive

# ---- deps ----
apt-get update >/dev/null
apt-get install -y --no-install-recommends \
  curl ca-certificates openssl iproute2 >/dev/null

[ -r "$CERT" ] || { echo "FATAL: missing CERT file: $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing KEY file:  $KEY";  exit 1; }

# ---- user / dir ----
getent group "$HY_GROUP" >/dev/null || groupadd --system "$HY_GROUP"
id -u "$HY_USER" >/dev/null 2>&1 || \
  useradd --system -g "$HY_GROUP" -M -d "$HY_STATE_DIR" -s /usr/sbin/nologin "$HY_USER"

install -d -o "$HY_USER" -g "$HY_GROUP" -m 750 "$HY_STATE_DIR"
install -d -o root      -g "$HY_GROUP" -m 750 "$HY_ETC_DIR"

# ---- latest tag via 302 ----
get_latest_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
    https://github.com/apernet/hysteria/releases/latest)" || return 1
  printf '%s\n' "${u##*/}"
}

TAG="$(get_latest_tag)" || { echo "Failed to resolve latest tag"; exit 1; }

# ---- pick asset by arch ----
uname_m="$(uname -m)"
ASSET=""

has_avx() {
  grep -qE '(^|\s)avx(\s|$)' /proc/cpuinfo 2>/dev/null
}

case "$uname_m" in
  x86_64|amd64)
    if has_avx; then
      ASSET="hysteria-linux-amd64-avx"
    else
      ASSET="hysteria-linux-amd64"
    fi
    ;;
  aarch64|arm64)
    ASSET="hysteria-linux-arm64"
    ;;
  *)
    echo "Unsupported arch: $uname_m" >&2
    exit 1
    ;;
esac

URL="https://github.com/apernet/hysteria/releases/download/${TAG}/${ASSET}"

# ---- download & install ----
tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

if ! curl -fL --retry 3 --retry-delay 1 -o "${tmpd}/${ASSET}" "$URL"; then
  echo "FATAL: download failed: $URL" >&2
  exit 1
fi

[ -s "${tmpd}/${ASSET}" ] || { echo "FATAL: downloaded file is empty: ${tmpd}/${ASSET}" >&2; exit 1; }

chmod 0755 "${tmpd}/${ASSET}"
install -m 0755 "${tmpd}/${ASSET}" "$HY_BIN"

# ---- first-time config only ----
if [ ! -f "$HY_CONF" ]; then
  if [ -z "${OBFS_PASS}" ]; then
    OBFS_PASS="$(openssl rand -base64 18 | tr -d '\n' | tr '/+' '_-' | cut -c1-24)"
  fi
  if [ -z "${AUTH_PASS}" ]; then
    AUTH_PASS="$(openssl rand -base64 18 | tr -d '\n' | tr '/+' '_-' | cut -c1-24)"
  fi

  cat >"$HY_CONF" <<EOF
listen: :${HY_PORT}

tls:
  cert: ${CERT}
  key: ${KEY}
  sniGuard: ${SNI_GUARD}

obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASS}

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

ignoreClientBandwidth: true
speedTest: false

disableUDP: false
udpIdleTimeout: 60s

auth:
  type: password
  password: ${AUTH_PASS}

outbounds:
  - name: direct
    type: direct
    direct:
      mode: ${DIRECT_MODE}
      fastOpen: ${FASTOPEN}
EOF

  chown root:"$HY_GROUP" "$HY_CONF"
  chmod 640 "$HY_CONF"

  echo "HYSTERIA TAG:  ${TAG}"
  echo "HYSTERIA ASSET:${ASSET}"
  echo "HYSTERIA AUTH: ${AUTH_PASS}"
  echo "HYSTERIA OBFS: ${OBFS_PASS}"
fi

# ---- systemd unit (create once) ----
if [ ! -f "$HY_SVC" ]; then
  cat >"$HY_SVC" <<EOF
[Unit]
Description=Hysteria 2 Server
Documentation=https://v2.hysteria.network/docs/getting-started/Server/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${HY_USER}
Group=${HY_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${HY_STATE_DIR}
ExecStart=${HY_BIN} server -c ${HY_CONF}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$HY_SVC"
fi

# ---- start / reload ----
systemctl daemon-reload
if systemctl is-enabled "$HY_SVC_NAME" >/dev/null 2>&1; then
  systemctl try-reload-or-restart "$HY_SVC_NAME" || systemctl restart "$HY_SVC_NAME"
else
  systemctl enable --now "$HY_SVC_NAME" || true
fi

"$HY_BIN" version 2>/dev/null || "$HY_BIN" --version 2>/dev/null || true
