bash -c '
set -euo pipefail

apt update
apt install -y curl jq ca-certificates uuid-runtime

# 用户与目录（先建组/用户，再 chown，避免你整合稿里“先 chown 后报错”的问题）
getent group tuic >/dev/null || groupadd --system tuic
id -u tuic >/dev/null 2>&1 || useradd --system -g tuic tuic
install -d -o tuic -g tuic -m 750 /etc/tuic

# 下载 glibc 版 server（二进制固定成这个资产名）
cd /tmp
curl -fLo tuic-server https://github.com/Itsusinn/tuic/releases/latest/download/tuic-server-x86_64-linux
chmod +x tuic-server
mv tuic-server /usr/local/bin/tuic-server

# 账号 & 配置（推荐带调优项；证书已存在于 /etc/tls）
UUID=$(uuidgen); PASS=$(openssl rand -hex 16)
cat >/etc/tuic/config.json <<EOF
{
  "server": "[::]:443",
  "users": { "$UUID": "$PASS" },
  "certificate": "/etc/tls/cert.pem",
  "private_key": "/etc/tls/key.pem",

  "congestion_control": "bbr",
  "alpn": ["h3"],

  "udp_relay_ipv6": true,
  "dual_stack": true,
  "zero_rtt_handshake": false,

  "auth_timeout": "3s",
  "task_negotiation_timeout": "3s",
  "max_idle_time": "30s",
  "max_external_packet_size": 1500,

  "log_level": "warn"
}
EOF
chown tuic:tuic /etc/tuic/config.json
chmod 640 /etc/tuic/config.json

# systemd unit（非 root 绑 443 用 AmbientCapabilities，不用 setcap）
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
ss -u -lpn | grep ":443 " || echo "未见 UDP/443 监听/占用"
'
