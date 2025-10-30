#!/usr/bin/env bash
# shadowquic-min: no-API latest/download, glibc only (x86_64/aarch64), plain binary install
set -euo pipefail

: "${SHQ_PORT:=443}"                        # ShadowQUIC 对外监听 UDP 端口
: "${SHQ_UPSTREAM_HOST:=www.debian.org}"    # 回源/伪装主机
: "${SHQ_UPSTREAM_PORT:=443}"               # 回源/伪装端口
: "${SHQ_LOG_LEVEL:=info}"                  # 日志等级: trace|debug|info|warn|error

SHQ_USER="shadowquic"
SHQ_GROUP="shadowquic"

SHQ_STATE_DIR="/var/lib/shadowquic"
SHQ_CONF_DIR="/etc/shadowquic"
SHQ_CONF_FILE="${SHQ_CONF_DIR}/server.yaml"

SHQ_BIN="/usr/local/bin/shadowquic"
SHQ_SERVICE_NAME="shadowquic"
SHQ_SERVICE="/etc/systemd/system/${SHQ_SERVICE_NAME}.service"

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y --no-install-recommends curl ca-certificates openssl iproute2

getent group "$SHQ_GROUP" >/dev/null || groupadd --system "$SHQ_GROUP"
id -u "$SHQ_USER" >/dev/null 2>&1 || \
  useradd --system -g "$SHQ_GROUP" -M -d "$SHQ_STATE_DIR" -s /usr/sbin/nologin "$SHQ_USER"

install -d -o "$SHQ_USER" -g "$SHQ_GROUP" -m 750 "$SHQ_STATE_DIR"
install -d -o root        -g "$SHQ_GROUP" -m 750 "$SHQ_CONF_DIR"

case "$(uname -m)" in
  x86_64|amd64)  ASSET="shadowquic-x86_64-linux"  ;;
  aarch64|arm64) ASSET="shadowquic-aarch64-linux" ;;
  *) echo "不支持的架构: $(uname -m)（仅 x86_64 / aarch64）" >&2; exit 1 ;;
esac

BASE_URL="https://github.com/spongebob888/shadowquic/releases/latest/download"

echo "[*] 下载 ${ASSET} …"
tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
bin_dl="${tmpd}/${ASSET}"
curl -fL --retry 3 --retry-delay 1 -o "$bin_dl" "${BASE_URL}/${ASSET}"
chmod +x "$bin_dl"
install -m 0755 "$bin_dl" "$SHQ_BIN"

if [ ! -f "$SHQ_CONF_FILE" ]; then
  SHQ_GEN_USER="${SHQ_GEN_USER:-$(openssl rand -hex 8)}"     # ~64bit
  SHQ_GEN_PASS="${SHQ_GEN_PASS:-$(openssl rand -hex 16)}"    # ~128bit

  cat >"$SHQ_CONF_FILE" <<EOF
inbound:
  type: shadowquic
  bind-addr: "[::]:${SHQ_PORT}"
  users:
    - username: "${SHQ_GEN_USER}"
      password: "${SHQ_GEN_PASS}"
  jls-upstream:
    addr: "${SHQ_UPSTREAM_HOST}:${SHQ_UPSTREAM_PORT}"
  alpn: ["h3"]
  congestion-control: bbr
  zero-rtt: true
outbound:
  type: direct
  dns-strategy: prefer-ipv4
log-level: "${SHQ_LOG_LEVEL}"
EOF

  chown root:"$SHQ_GROUP" "$SHQ_CONF_FILE"
  chmod 640 "$SHQ_CONF_FILE"

  echo "ShadowQUIC 用户名: ${SHQ_GEN_USER}"
  echo "ShadowQUIC 密码:   ${SHQ_GEN_PASS}"
fi

if [ ! -f "$SHQ_SERVICE" ]; then
  cat >"$SHQ_SERVICE" <<EOF
[Unit]
Description=ShadowQUIC Server
Documentation=https://github.com/spongebob888/shadowquic
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${SHQ_USER}
Group=${SHQ_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${SHQ_STATE_DIR}
ExecStart=${SHQ_BIN} -c ${SHQ_CONF_FILE}
Restart=on-failure
RestartSec=3s
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SHQ_SERVICE"
fi

systemctl daemon-reload
if systemctl is-enabled "$SHQ_SERVICE_NAME" >/dev/null 2>&1; then
  systemctl try-reload-or-restart "$SHQ_SERVICE_NAME" || systemctl restart "$SHQ_SERVICE_NAME"
else
  systemctl enable --now "$SHQ_SERVICE_NAME" || true
fi

echo
"$SHQ_BIN" -V 2>/dev/null || "$SHQ_BIN" --version 2>/dev/null || true
echo "UDP/${SHQ_PORT} 监听检查："
ss -Hnplu | grep -E ":${SHQ_PORT}([^0-9]|$)" || echo "未见 UDP/${SHQ_PORT} 占用"
