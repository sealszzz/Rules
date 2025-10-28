#!/usr/bin/env bash
set -euo pipefail

# ========= 依赖 =========
apt update
apt install -y --no-install-recommends \
  curl ca-certificates git pkg-config build-essential xz-utils uuid-runtime xxd iproute2  # iproute2 提供 ss

# ========= 安装/激活 Rust 工具链 =========
if ! command -v cargo >/dev/null 2>&1; then
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
# 加载 cargo 环境变量（当前 shell），文件可能不存在，需容错
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
export PATH="$HOME/.cargo/bin:$PATH"

# ========= 用 cargo 从 Git 仓库安装最新版 tuic-server =========
# 说明：--git 指向 Itsusinn/tuic 仓库（workspace），--locked 使用仓库的 Cargo.lock，
#       --force 覆盖到最新提交（即使版本号没变也会更新）
if ! cargo install --git https://github.com/Itsusinn/tuic --locked --force tuic-server; then
  echo "[!] --locked 构建失败，回退为不带 --locked 再试一次……"
  cargo install --git https://github.com/Itsusinn/tuic --force tuic-server
fi

# 安装到 /usr/local/bin（便于 systemd 调用）；备份旧二进制
if [ -x /usr/local/bin/tuic-server ]; then
  cp -a /usr/local/bin/tuic-server "/usr/local/bin/tuic-server.bak.$(date +%Y%m%d%H%M%S)" || true
fi
install -m 0755 "$HOME/.cargo/bin/tuic-server" /usr/local/bin/tuic-server

# ========= 用户与目录 =========
getent group tuic >/dev/null || groupadd --system tuic
id -u tuic >/dev/null 2>&1 || useradd --system -g tuic -M -d /var/lib/tuic -s /usr/sbin/nologin tuic
install -d -o tuic -g tuic -m 750 /var/lib/tuic
install -d -o root -g tuic -m 750 /etc/tuic

# ========= 首次生成配置（之后不改）=========
if [ ! -f /etc/tuic/config.json ]; then
  UUID="$(uuidgen)"
  PASS="$(head -c16 /dev/urandom | xxd -p)"

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

  chown root:tuic /etc/tuic/config.json
  chmod 640      /etc/tuic/config.json

  echo "TUIC UUID: $UUID"
  echo "TUIC PASS: $PASS"
fi

# ========= systemd =========
if [ ! -f /etc/systemd/system/tuic-server.service ]; then
  cat >/etc/systemd/system/tuic-server.service <<EOF
[Unit]
Description=TUIC Server (built from git via cargo)
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
  systemctl daemon-reload
  systemctl enable --now tuic-server
else
  systemctl try-reload-or-restart tuic-server || systemctl restart tuic-server
fi

# ========= 摘要 =========
echo "== tuic-server version =="
/usr/local/bin/tuic-server -V || true
echo
echo "UDP/443 监听检查（注意与其它 QUIC/HTTP3 服务冲突）"
ss -Hnplu | grep ":443" || echo "未见 UDP/443 监听/占用"
