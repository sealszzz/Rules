#!/usr/bin/env bash
set -euo pipefail

: "${PORT:=443}"
: "${METHOD:=aes-256-gcm}"
: "${PASSWORD:=}"

BIN="/usr/local/bin/leaf"
CONF_DIR="/etc/leaf"
CONF="${CONF_DIR}/config.json"
STATE_DIR="/var/lib/leaf"
SERVICE="/etc/systemd/system/leaf.service"
REPO="eycorsican/leaf"
USER="leaf"
GROUP="leaf"

export DEBIAN_FRONTEND=noninteractive
[ "${EUID:-$(id -u)}" -eq 0 ] || exit 1

dpkg -s curl ca-certificates gzip openssl >/dev/null 2>&1 || {
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends curl ca-certificates gzip openssl >/dev/null
}

getent group "$GROUP" >/dev/null 2>&1 || groupadd --system "$GROUP"
id -u "$USER" >/dev/null 2>&1 || \
  useradd --system -g "$GROUP" -M -d "$STATE_DIR" -s /usr/sbin/nologin "$USER"

mkdir -p "$STATE_DIR" "$CONF_DIR"
chown -R "$USER:$GROUP" "$STATE_DIR"
chown root:"$GROUP" "$CONF_DIR"
chmod 750 "$CONF_DIR"

arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "x86_64-unknown-linux-musl" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
    *) exit 1 ;;
  esac
}

tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/${REPO}/releases/latest)"
tag="${tag##*/}"

tmp="$(mktemp -d)"
curl -fsSL "https://github.com/${REPO}/releases/download/${tag}/leaf-$(arch).gz" -o "$tmp/leaf.gz"
gzip -d "$tmp/leaf.gz"
install -m 0755 "$tmp/leaf" "$BIN"
rm -rf "$tmp"

if [ ! -f "$CONF" ]; then
  [ -n "$PASSWORD" ] || PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
  cat >"$CONF" <<EOF
{
  "log": { "level": "warn" },

  "inbounds": [
    {
      "protocol": "shadowsocks",
      "tag": "ss_in",
      "settings": {
        "address": "::",
        "port": ${PORT},
        "method": "${METHOD}",
        "password": "${PASSWORD}"
      }
    }
  ],

  "outbounds": [
    {
      "protocol": "direct",
      "tag": "direct"
    }
  ],

  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["ss_in"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF
  chown root:"$GROUP" "$CONF"
  chmod 640 "$CONF"
fi

if [ ! -f "$SERVICE" ]; then
  cat >"$SERVICE" <<EOF
[Unit]
Description=Leaf Shadowsocks
After=network-online.target

[Service]
User=${USER}
Group=${GROUP}
ExecStart=${BIN} -c ${CONF}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable leaf >/dev/null 2>&1 || true
systemctl restart leaf

ver="$("$BIN" --version 2>/dev/null | head -n1 || true)"
echo "Leaf BIN: ${ver}"
echo "Listen:   [::]:${PORT}"
echo "Method:   ${METHOD}"
echo "Password: $(awk -F\" '/password/{print $4;exit}' "$CONF")"
