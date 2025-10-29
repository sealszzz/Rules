#!/usr/bin/env bash
set -euo pipefail

# ========= 可调参数 =========
: "${TUIC_PORT:=443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

# 构建特性：默认用 aws-lc-rs；如需 ring：导出 TUIC_FEATURES=ring 并保持 TUIC_NO_DEFAULT=0
: "${TUIC_FEATURES:=aws-lc-rs}"
: "${TUIC_NO_DEFAULT:=0}"   # 1 => --no-default-features；0 => 使用默认特性

# 随机凭据（可预设 TUIC_UUID/TUIC_PASS 覆盖）
: "${TUIC_UUID:=$(uuidgen)}"
: "${TUIC_PASS:=$(openssl rand -hex 16)}"

# ========= 依赖 =========
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends \
  git build-essential pkg-config curl ca-certificates uuid-runtime openssl xz-utils lld iproute2

# ========= 证书自检 =========
[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

# ========= 运行用户与目录 =========
getent group tuic >/dev/null || groupadd --system tuic
id -u tuic >/dev/null 2>&1 || useradd --system -g tuic -M -d /var/lib/tuic -s /usr/sbin/nologin tuic
install -d -o tuic -g tuic -m 750 /var/lib/tuic
install -d -o root -g tuic -m 750 /etc/tuic

# ========= 构建环境（把缓存与产物放磁盘，避免 /tmp 爆）=========
export CARGO_HOME=/var/lib/tuic/cargo
export CARGO_TARGET_DIR=/var/lib/tuic/target
export TMPDIR=/var/tmp
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_NET_GIT_FETCH_WITH_CLI=true
# 降低资源占用；2G 机子更稳
export RUSTFLAGS="${RUSTFLAGS:-} -C lto=off -C codegen-units=8"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}"

# ========= 安装 rustup/cargo（若未安装）=========
if ! command -v cargo >/dev/null 2>&1; then
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  export PATH="$HOME/.cargo/bin:$PATH"
fi

# ========= 获取 main 最新提交（不用 GitHub API，避免 403）=========
echo "[*] 解析 main 最新提交..."
sha="$(git ls-remote https://github.com/Itsusinn/tuic.git refs/heads/main | awk '{print $1}')"
[ -n "${sha:-}" ] || { echo "无法获取 main 最新提交"; exit 1; }
echo "[*] 将编译 Itsusinn/tuic @ ${sha:0:12}（HEAD of main）"

# ========= 源码安装（只跑一次，不锁依赖）=========
FEAT_ARGS=()
[ "${TUIC_NO_DEFAULT}" = "1" ] && FEAT_ARGS+=(--no-default-features)
[ -n "${TUIC_FEATURES:-}" ] && FEAT_ARGS+=(--features "${TUIC_FEATURES}")

set -x
cargo install \
  --git https://github.com/Itsusinn/tuic.git \
  --rev "$sha" \
  --root "$CARGO_HOME" \
  --force \
  "${FEAT_ARGS[@]}" \
  tuic-server
set +x

# 安装到 PATH
install -m 0755 "$CARGO_HOME/bin/tuic-server" /usr/local/bin/tuic-server

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
/usr/local/bin/tuic-server -V 2>/dev/null || /usr/local/bin/tuic-server --version 2>/dev/null || true
echo "已构建提交：${sha:0:12}"
echo "UDP/${TUIC_PORT} 监听检查："
ss -Hnplu | grep -E ":${TUIC_PORT}([^0-9]|$)" || echo "未见 UDP/${TUIC_PORT} 占用"
