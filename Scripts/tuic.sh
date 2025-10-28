#!/usr/bin/env bash
set -euo pipefail

# ========= 可调参数（可用环境变量覆盖）=========
: "${TUIC_PORT:=443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

# 随机凭据（可预先导出 TUIC_UUID/TUIC_PASS 覆盖）
: "${TUIC_UUID:=$(uuidgen)}"
: "${TUIC_PASS:=$(openssl rand -hex 16)}"

# ========= 基础依赖（两种路径都需要）=========
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends curl ca-certificates uuid-runtime openssl iproute2

# ========= 证书自检 =========
[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

# ========= TUIC 运行用户与目录 =========
getent group tuic >/dev/null || groupadd --system tuic
id -u tuic >/dev/null 2>&1 || useradd --system -g tuic -M -d /var/lib/tuic -s /usr/sbin/nologin tuic
install -d -o tuic -g tuic -m 750 /var/lib/tuic
install -d -o root -g tuic -m 750 /etc/tuic

# ========= 询问安装方式（默认 N：Release 二进制；y/Y：cargo 源码）=========
USE_CARGO=0
read -rp "使用 cargo 源码编译安装 tuic-server？[y/N] " _ans || true
case "${_ans:-}" in
  y|Y) USE_CARGO=1 ;;
esac

# ========= 若选择 cargo，再补齐编译依赖并安装 rustup =========
if [ "$USE_CARGO" -eq 1 ]; then
  apt install -y --no-install-recommends git build-essential pkg-config xz-utils
  if ! command -v cargo >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  fi
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  export PATH="$HOME/.cargo/bin:$PATH"
fi

# ========= 安装 tuic-server =========
if [ "$USE_CARGO" -eq 1 ]; then
  echo "[*] 通过 cargo 源码安装 tuic-server（拉取最新提交）..."
  set +e
  cargo install --git https://github.com/Itsusinn/tuic --locked --force tuic-server
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "[!] --locked 失败，回退不带 --locked ..."
    cargo install --git https://github.com/Itsusinn/tuic --force tuic-server
    rc=$?
  fi
  set -e
  [ $rc -eq 0 ] || { echo "cargo 安装失败"; exit 1; }
  install -m 0755 "$HOME/.cargo/bin/tuic-server" /usr/local/bin/tuic-server
else
  echo "[*] 安装 Release 二进制 ..."
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  ASSET="tuic-server-x86_64-linux";  ALT="tuic-server-x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) ASSET="tuic-server-aarch64-linux"; ALT="tuic-server-aarch64-unknown-linux-gnu" ;;
    *) echo "不支持的架构: $arch" >&2; exit 1 ;;
  esac
  cd /tmp
  if ! curl -fLo tuic-server "https://github.com/Itsusinn/tuic/releases/latest/download/${ASSET}"; then
    echo "[!] 主资产下载失败，尝试回退：${ALT}"
    curl -fLo tuic-server "https://github.com/Itsusinn/tuic/releases/latest/download/${ALT}"
  fi
  chmod +x tuic-server
  install -m 0755 tuic-server /usr/local/bin/tuic-server
  rm -f tuic-server
fi

# ========= 首次生成配置（存在则不覆盖）=========
if [ ! -f /etc/tuic/config.json ]; then
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

# ========= systemd =========
if [ ! -f /etc/systemd/system/tuic-server.service ]; then
  # 不需要变量展开 → 带引号的 EOF 更安全
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

systemctl daemon-reload
systemctl enable --now tuic-server || true
systemctl try-reload-or-restart tuic-server || systemctl restart tuic-server

# ========= 摘要 =========
echo
echo "== tuic-server version =="
/usr/local/bin/tuic-server -V || true
echo
echo "UDP/${TUIC_PORT} 监听检查（注意与其它 QUIC/HTTP3 冲突）"
ss -Hnplu | grep -E ":${TUIC_PORT}([^0-9]|$)" || echo "未见 UDP/${TUIC_PORT} 监听/占用"
