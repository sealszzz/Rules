#!/usr/bin/env bash
# shadowquic-min: no-API latest/download, glibc only (x86_64/aarch64), plain binary install
set -euo pipefail

: "${SQ_PORT:=443}"
: "${SQ_UPSTREAM_HOST:=www.debian.org}"
: "${SQ_UPSTREAM_PORT:=443}"
: "${SQ_LOG_LEVEL:=warn}"           # trace | debug | info | warn | error
: "${SQ_DNS_STRATEGY:=prefer-ipv4}" # prefer-ipv4 | prefer-ipv6 | ipv4-only | ipv6-only

SQ_USER="shadowquic"
SQ_GROUP="shadowquic"

SQ_STATE_DIR="/var/lib/shadowquic"
SQ_CONF_DIR="/etc/shadowquic"
SQ_CONF_FILE="${SQ_CONF_DIR}/server.yaml"

SQ_BIN="/usr/local/bin/shadowquic"
SQ_SERVICE_NAME="shadowquic"
SQ_SERVICE="/etc/systemd/system/${SQ_SERVICE_NAME}.service"

export DEBIAN_FRONTEND=noninteractive

apt-get update >/dev/null
apt-get install -y --no-install-recommends curl ca-certificates openssl iproute2 >/dev/null

getent group "$SQ_GROUP" >/dev/null || groupadd --system "$SQ_GROUP"
id -u "$SQ_USER" >/dev/null 2>&1 || \
  useradd --system -g "$SQ_GROUP" -M -d "$SQ_STATE_DIR" -s /usr/sbin/nologin "$SQ_USER"

install -d -o "$SQ_USER" -g "$SQ_GROUP" -m 750 "$SQ_STATE_DIR"
install -d -o root -g "$SQ_GROUP" -m 750 "$SQ_CONF_DIR"

case "$(uname -m)" in
  x86_64|amd64)  ASSET="shadowquic-x86_64-linux" ;;
  aarch64|arm64) ASSET="shadowquic-aarch64-linux" ;;
  *) echo "FATAL: unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

BASE_URL="https://github.com/spongebob888/shadowquic/releases/latest/download"

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
bin_dl="${tmpd}/${ASSET}"

curl -fL --retry 3 --retry-delay 1 -o "$bin_dl" "${BASE_URL}/${ASSET}"
install -m 0755 "$bin_dl" "$SQ_BIN"

if [ ! -f "$SQ_CONF_FILE" ]; then
  SQ_GEN_USER="${SQ_GEN_USER:-$(openssl rand -hex 8)}"
  SQ_GEN_PASS="${SQ_GEN_PASS:-$(openssl rand -hex 16)}"

  cat >"$SQ_CONF_FILE" <<EOF
inbound:
  type: shadowquic
  bind-addr: "[::]:${SQ_PORT}"
  users:
    - username: "${SQ_GEN_USER}"
      password: "${SQ_GEN_PASS}"
  jls-upstream:
    addr: "${SQ_UPSTREAM_HOST}:${SQ_UPSTREAM_PORT}"
  alpn: ["h3"]
  congestion-control: bbr
  zero-rtt: true
outbound:
  type: direct
  dns-strategy: ${SQ_DNS_STRATEGY}
log-level: "${SQ_LOG_LEVEL}"
EOF

  chown root:"$SQ_GROUP" "$SQ_CONF_FILE"
  chmod 640 "$SQ_CONF_FILE"
fi

if [ ! -f "$SQ_SERVICE" ]; then
  cat >"$SQ_SERVICE" <<EOF
[Unit]
Description=ShadowQUIC Server
Documentation=https://github.com/spongebob888/shadowquic
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${SQ_USER}
Group=${SQ_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${SQ_STATE_DIR}
ExecStart=${SQ_BIN} -c ${SQ_CONF_FILE}
Restart=on-failure
RestartSec=3s
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SQ_SERVICE"
fi

systemctl daemon-reload
if systemctl is-enabled "$SQ_SERVICE_NAME" >/dev/null 2>&1; then
  systemctl try-reload-or-restart "$SQ_SERVICE_NAME" || systemctl restart "$SQ_SERVICE_NAME"
else
  systemctl enable --now "$SQ_SERVICE_NAME" || true
fi

echo
echo "[*] ShadowQUIC version:"
"$SQ_BIN" -V 2>/dev/null || "$SQ_BIN" --version 2>/dev/null || true
