#!/usr/bin/env bash
set -euo pipefail

# ========= 可调参数 =========
: "${TUIC_PORT:=443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

BIN="/usr/local/bin/tuic-server"

export DEBIAN_FRONTEND=noninteractive

# ========= 基础依赖 =========
apt update
apt install -y --no-install-recommends \
  curl jq ca-certificates uuid-runtime openssl iproute2 tar unzip xz-utils

# ========= 证书自检 =========
[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

# ========= 系统用户与目录 =========
getent group tuic >/dev/null || groupadd --system tuic
id -u tuic >/dev/null 2>&1 || useradd --system -g tuic -M -d /var/lib/tuic -s /usr/sbin/nologin tuic
install -d -o tuic  -g tuic  -m 750 /var/lib/tuic
install -d -o root  -g tuic  -m 750 /etc/tuic

# ========= 获取最新 Release 并挑选资产 (GNU优先, musl兜底) =========
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)  pat_arch="(x86_64|amd64)";;
  aarch64|arm64) pat_arch="(aarch64|arm64)";;
  *) echo "不支持的架构: $arch" >&2; exit 1;;
esac

echo "[*] 获取 tuic 最新 Release..."
json="$(curl -fsSL --retry 3 --retry-delay 1 https://api.github.com/repos/Itsusinn/tuic/releases/latest || true)"
if [ -z "$json" ] || [ "$(echo "$json" | jq -r '.message // empty')" = "Not Found" ]; then
  echo "GitHub API 获取失败。"
  exit 1
fi

tag="$(echo "$json" | jq -r '.tag_name')"
assets="$(echo "$json" | jq -r '.assets[].name')"

pick_asset() {
  # $1: 架构正则, $2: gnu|musl
  echo "$assets" | grep -i -E "^tuic-server-.*${1}.*(linux|unknown-linux).*${2}(\.tar\.(gz|xz)|\.zip|)$" | head -n1 || true
}

asset="$(pick_asset "$pat_arch" "gnu")"
[ -n "$asset" ] || asset="$(pick_asset "$pat_arch" "musl")"
[ -n "$asset" ] || asset="$(echo "$assets" | grep -i -E "^tuic-server-.*${pat_arch}.*(linux|unknown-linux).*(\.tar\.(gz|xz)|\.zip|)$" | head -n1 || true)"
[ -n "$asset" ] || { echo "未找到匹配的 Release 资产"; exit 1; }

url="$(echo "$json" | jq -r ".assets[] | select(.name==\"$asset\") | .browser_download_url")"
[ -n "$url" ] || { echo "解析下载链接失败"; exit 1; }

echo "[*] 将安装版本: $tag"
echo "[*] 选择资产: $asset"

# ========= 下载并安装二进制 =========
tmpd="$(mktemp -d)"
trap 't="${tmpd-}"; [ -n "$t" ] && rm -rf -- "$t"' EXIT

curl -fL "$url" -o "$tmpd/pkg"

case "$asset" in
  *.tar.gz)  mkdir -p "$tmpd/u" && tar -xzf "$tmpd/pkg" -C "$tmpd/u" ;;
  *.tar.xz)  mkdir -p "$tmpd/u" && tar -xJf "$tmpd/pkg" -C "$tmpd/u" ;;
  *.zip)     mkdir -p "$tmpd/u" && unzip -q "$tmpd/pkg" -d "$tmpd/u" ;;
  *)
    mkdir -p "$tmpd/u"
    cp "$tmpd/pkg" "$tmpd/u/tuic-server"
    chmod +x "$tmpd/u/tuic-server"
    ;;
esac

binpath="$(find "$tmpd/u" -maxdepth 3 -type f -name 'tuic-server' -perm -u+x | head -n1 || true)"
[ -n "$binpath" ] || { echo "未在资产内找到可执行文件 tuic-server"; exit 1; }

install -m 0755 "$binpath" "$BIN"

# ========= 首次生成配置（存在则不覆盖）=========
if [ ! -f /etc/tuic/config.json ]; then
  TUIC_UUID="${TUIC_UUID:-$(uuidgen)}"
  TUIC_PASS="${TUIC_PASS:-$(openssl rand -hex 16)}"

  cat >/etc/tuic/config.json <<EOF
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

  chown root:tuic /etc/tuic/config.json
  chmod 640      /etc/tuic/config.json

  echo "TUIC UUID: ${TUIC_UUID}"
  echo "TUIC PASS: ${TUIC_PASS}"
fi

# ========= systemd（只在第一次创建）=========
if [ ! -f /etc/systemd/system/tuic-server.service ]; then
  cat >/etc/systemd/system/tuic-server.service <<'EOF'
[Unit]
Description=TUIC Server (Itsusinn)
Documentation=https://github.com/Itsusinn/tuic
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=tuic
Group=tuic
Type=simple
UMask=0077
WorkingDirectory=/var/lib/tuic
ExecStart=/usr/local/bin/tuic-server -c /etc/tuic/config.json
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

# ========= 启动/重启 =========
systemctl daemon-reload
if systemctl is-enabled tuic-server >/dev/null 2>&1; then
  systemctl try-reload-or-restart tuic-server || systemctl restart tuic-server
else
  systemctl enable --now tuic-server || true
fi

# ========= 摘要 =========
echo
"$BIN" -V 2>/dev/null || "$BIN" --version 2>/dev/null || true
echo "UDP/${TUIC_PORT} 监听检查："
ss -Hnplu | grep -E ":${TUIC_PORT}([^0-9]|$)" || echo "未见 UDP/${TUIC_PORT} 占用"
