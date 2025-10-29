#!/usr/bin/env bash
set -euo pipefail

# ========= 可调参数 =========
: "${TUIC_PORT:=443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

# 构建特性：默认走 ring（轻量内存占用）。如需 aws-lc-rs：导出 TUIC_FEATURES=aws-lc-rs 且去掉 NO_DEFAULT。
: "${TUIC_FEATURES:=aws-lc-rs}"
: "${TUIC_NO_DEFAULT:=0}"   # 0 => 使用默认特性（默认就包含 aws-lc-rs）

# 随机凭据（可预设 TUIC_UUID/TUIC_PASS 覆盖）
: "${TUIC_UUID:=$(uuidgen)}"
: "${TUIC_PASS:=$(openssl rand -hex 16)}"

# ========= 依赖 =========
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends \
  git build-essential pkg-config curl jq ca-certificates uuid-runtime openssl xz-utils

# ========= 证书自检 =========
[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

# ========= 运行用户与目录 =========
getent group tuic >/dev/null || groupadd --system tuic
id -u tuic >/dev/null 2>&1 || useradd --system -g tuic -M -d /var/lib/tuic -s /usr/sbin/nologin tuic
install -d -o tuic -g tuic -m 750 /var/lib/tuic
install -d -o root -g tuic -m 750 /etc/tuic

# ========= 构建环境（把缓存与产物放磁盘，避免 /tmp 崩溃） =========
export CARGO_HOME=/var/lib/tuic/cargo
export CARGO_TARGET_DIR=/var/lib/tuic/target
export TMPDIR=/var/tmp
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_NET_GIT_FETCH_WITH_CLI=true

# 可适当降低内存占用（覆盖 Cargo.toml 里的 LTO/FAT 等）
export RUSTFLAGS="${RUSTFLAGS:-} -C lto=off -C codegen-units=8"

# 安装 rustup/cargo（若未安装）
if ! command -v cargo >/dev/null 2>&1; then
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
fi

# ========= 是否用 cargo 源码安装？（默认 N：Release 二进制）=========
USE_CARGO=0
read -rp "使用 cargo 源码安装 tuic-server（不锁依赖，只跑一次失败即退出）？[y/N] " _ans || true
case "${_ans:-}" in y|Y) USE_CARGO=1 ;; esac

if [ "$USE_CARGO" -eq 1 ]; then
  echo "[*] 解析 main 最新提交..."
  # 用 git ls-remote 不走 GitHub API，减少 403 风险
  sha="$(git ls-remote https://github.com/Itsusinn/tuic.git refs/heads/main | awk '{print $1}')"
  [ -n "${sha:-}" ] || { echo "无法获取 main 最新提交"; exit 1; }

  echo "[*] clone @ $sha（浅克隆）..."
  src="$(mktemp -d)"
  trap 't="${src-}"; [ -n "$t" ] && rm -rf -- "$t"' EXIT
  git clone --depth=1 --branch main https://github.com/Itsusinn/tuic "$src"
  ( cd "$src" && git rev-parse --short=12 HEAD )

  echo "[*] cargo build（不锁依赖，只跑一次；默认 --features ${TUIC_FEATURES}）..."
  set -x
  if [ "${TUIC_NO_DEFAULT}" = "1" ]; then
    cargo build --release \
      --manifest-path "$src/tuic-server/Cargo.toml" \
      --no-default-features --features "${TUIC_FEATURES}"
  else
    cargo build --release \
      --manifest-path "$src/tuic-server/Cargo.toml" \
      --features "${TUIC_FEATURES}"
  fi
  set +x

  install -m 0755 "$CARGO_TARGET_DIR/release/tuic-server" /usr/local/bin/tuic-server
  echo "== Built tuic-server @ ${sha}（HEAD of main），deps: 最新兼容范围 =="
else
  echo "[*] 安装 Release 二进制（只尝试一次，不回退）..."
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  asset="tuic-server-x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) asset="tuic-server-aarch64-unknown-linux-gnu" ;;
    *) echo "不支持的架构: $arch"; exit 1 ;;
  esac
  rel_json="$(curl -fsSL https://api.github.com/repos/Itsusinn/tuic/releases/latest)"
  url="$(echo "$rel_json" | jq -r ".assets[] | select(.name==\"$asset\") | .browser_download_url")"
  [ -n "$url" ] || { echo "没有匹配的 Release 资产: $asset"; exit 1; }

  tmpd="$(mktemp -d)"
  trap 't="${tmpd-}"; [ -n "$t" ] && rm -rf -- "$t"' EXIT
  curl -fL "$url" -o "$tmpd/tuic-server"
  install -m 0755 "$tmpd/tuic-server" /usr/local/bin/tuic-server
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

echo
/usr/local/bin/tuic-server -V 2>/dev/null || /usr/local/bin/tuic-server --version 2>/dev/null || true
echo "UDP/${TUIC_PORT} 监听检查："
ss -Hnplu | grep -E ":${TUIC_PORT}([^0-9]|$)" || echo "未见 UDP/${TUIC_PORT} 占用"
