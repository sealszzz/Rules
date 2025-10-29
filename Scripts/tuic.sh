#!/usr/bin/env bash
set -euo pipefail

# ========= 可调路径/参数（如无必要别改）=========
: "${TUIC_PORT:=443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

TUIC_USER="tuic"
TUIC_GROUP="tuic"

TUIC_STATE_DIR="/var/lib/tuic"
TUIC_CONF_DIR="/etc/tuic"
TUIC_CONF_FILE="${TUIC_CONF_DIR}/config.json"
TUIC_BIN="/usr/local/bin/tuic-server"
TUIC_SERVICE="/etc/systemd/system/tuic-server.service"

export DEBIAN_FRONTEND=noninteractive

# ========= 依赖 =========
apt update
apt install -y --no-install-recommends \
  curl jq ca-certificates uuid-runtime openssl iproute2

# ========= 证书自检 =========
[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

# ========= 系统用户与目录（第一次会创建，之后复用）=========
getent group "$TUIC_GROUP" >/dev/null || groupadd --system "$TUIC_GROUP"
id -u "$TUIC_USER" >/dev/null 2>&1 || \
  useradd --system -g "$TUIC_GROUP" -M -d "$TUIC_STATE_DIR" -s /usr/sbin/nologin "$TUIC_USER"

install -d -o "$TUIC_USER" -g "$TUIC_GROUP" -m 750 "$TUIC_STATE_DIR"
install -d -o root        -g "$TUIC_GROUP" -m 750 "$TUIC_CONF_DIR"

# ========= 选取 release 里的正确二进制 (glibc优先, musl兜底) =========
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)   wanted_arch="x86_64"   ;;
  aarch64|arm64)  wanted_arch="aarch64"  ;;
  i686|i386)      wanted_arch="i686"     ;;
  *) echo "不支持的架构: $arch" >&2; exit 1 ;;
esac

echo "[*] 获取 tuic 最新 Release 信息..."
rel_json="$(curl -fsSL --retry 3 --retry-delay 1 https://api.github.com/repos/Itsusinn/tuic/releases/latest)"
[ -n "$rel_json" ] || { echo "获取 release 信息失败"; exit 1; }

tag="$(echo "$rel_json" | jq -r '.tag_name')"
assets="$(echo "$rel_json" | jq -r '.assets[].name')"

pick_asset_glibc="tuic-server-${wanted_arch}-linux"
pick_asset_musl="tuic-server-${wanted_arch}-linux-musl"

chosen_asset=""
if echo "$assets" | grep -qx "$pick_asset_glibc"; then
  chosen_asset="$pick_asset_glibc"
elif echo "$assets" | grep -qx "$pick_asset_musl"; then
  chosen_asset="$pick_asset_musl"
else
  echo "没有匹配的 Release 资产 (${pick_asset_glibc} / ${pick_asset_musl})"
  echo "可用资产列表："
  echo "$assets"
  exit 1
fi

download_url="$(echo "$rel_json" | jq -r ".assets[] | select(.name==\"$chosen_asset\") | .browser_download_url")"
[ -n "$download_url" ] || { echo "解析下载链接失败"; exit 1; }

echo "[*] 将安装版本: $tag"
echo "[*] 选择资产: $chosen_asset"

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

curl -fL "$download_url" -o "$tmpd/tuic-server"
chmod +x "$tmpd/tuic-server"

install -m 0755 "$tmpd/tuic-server" "$TUIC_BIN"

# ========= 首次生成配置（存在则不覆盖）=========
if [ ! -f "$TUIC_CONF_FILE" ]; then
  TUIC_UUID="${TUIC_UUID:-$(uuidgen)}"
  TUIC_PASS="${TUIC_PASS:-$(openssl rand -hex 16)}"

  cat >"$TUIC_CONF_FILE" <<EOF
{
  "server": "[::]:${TUIC_PORT}",
  "users": {
    "${TUIC_UUID}":
    "${TUIC_PASS}"
  },
  "certificate": "${CERT}",
  "private_key": "${KEY}",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "udp_relay_ipv6": true,
  "dual_stack": true,
  "zero_rtt_handshake": false,
  "auth_timeout": "3s",
  "task_negotiation_timeout": "3s",
  "max_external_packet_size": 1500,
  "stream_timeout": "60s",
  "log_level": "warn"
}
EOF

  chown root:"$TUIC_GROUP" "$TUIC_CONF_FILE"
  chmod 640           "$TUIC_CONF_FILE"

  echo "TUIC UUID: ${TUIC_UUID}"
  echo "TUIC PASS: ${TUIC_PASS}"
fi

# ========= systemd service（只在第一次创建）=========
if [ ! -f "$TUIC_SERVICE" ]; then
  cat >"$TUIC_SERVICE" <<EOF
[Unit]
Description=TUIC Server (Itsusinn)
Documentation=https://github.com/Itsusinn/tuic
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${TUIC_USER}
Group=${TUIC_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${TUIC_STATE_DIR}
ExecStart=${TUIC_BIN} -c ${TUIC_CONF_FILE}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s
Environment=RUST_LOG=warn

[Install]
WantedBy=multi-user.target
EOF
fi

# ========= 启动 / 重载 =========
systemctl daemon-reload
if systemctl is-enabled tuic-server >/dev/null 2>&1; then
  systemctl try-reload-or-restart tuic-server || systemctl restart tuic-server
else
  systemctl enable --now tuic-server || true
fi

# ========= 摘要 =========
echo
"$TUIC_BIN" -V 2>/dev/null || "$TUIC_BIN" --version 2>/dev/null || true
echo "UDP/${TUIC_PORT} 监听检查："
ss -Hnplu | grep -E ":${TUIC_PORT}([^0-9]|$)" || echo "未见 UDP/${TUIC_PORT} 占用"
