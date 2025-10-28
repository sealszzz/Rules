#!/usr/bin/env bash
set -euo pipefail

apt update
apt install -y curl ca-certificates uuid-runtime openssl

# --- 用户与目录：root 管理 /etc，tuic 拥有 /var/lib ---
getent group tuic >/dev/null || groupadd --system tuic
id -u tuic >/dev/null 2>&1 || useradd --system -g tuic -M -d /var/lib/tuic -s /usr/sbin/nologin tuic
install -d -o tuic -g tuic -m 750 /var/lib/tuic
install -d -o root -g tuic -m 750 /etc/tuic

# --- 架构检测 + 下载 itsusinn glibc 版 ---
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) ASSET="tuic-server-x86_64-linux" ;;
  aarch64|arm64) ASSET="tuic-server-aarch64-linux" ;;
  *) echo "不支持的架构: $arch" >&2; exit 1 ;;
esac

cd /tmp
if ! curl -fLo tuic-server "https://github.com/Itsusinn/tuic/releases/latest/download/${ASSET}"; then
  echo "[!] 下载失败：${ASSET}"
  # 可选回退：尝试 unknown-linux-gnu 命名（有的版本用这个）
  alt="${ASSET/linux/unknown-linux-gnu}"
  echo "[*] 回退尝试：${alt}"
  curl -fLo tuic-server "https://github.com/Itsusinn/tuic/releases/latest/download/${alt}"
fi
chmod +x tuic-server
mv tuic-server /usr/local/bin/tuic-server

# --- 账号 & 配置（证书已在 /etc/tls）---
UUID="$(uuidgen)"
PASS="$(openssl rand -hex 16)"

cat >/etc/tuic/config.json <<EOF
{
  "server": "[::]:443",
  "users": {
    "$UUID":
    "$PASS"
  },
  "certificate": "/etc/tls/cert.pem",
  "private_key": "/etc/tls/key.pem",
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

# 配置文件：root 写，tuic 组读
chown root:tuic /etc/tuic/config.json
chmod 640 /etc/tuic/config.json

# --- systemd unit（非 root 绑 443 用 AmbientCapabilities，不用 setcap）---
cat >/etc/systemd/system/tuic-server.service <<EOF
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tuic-server

echo "UUID=$UUID"
echo "PASS=$PASS"
echo
echo "状态："
systemctl --no-pager --full status tuic-server || true
echo
echo "UDP/443 占用检查（HTTP/3 会抢 UDP/443）："
ss -u -lpn | grep ":443" || echo "未见 UDP/443 监听/占用"
