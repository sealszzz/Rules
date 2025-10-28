#!/usr/bin/env bash
set -euo pipefail

# ========= 可调参数（可用环境变量覆盖）=========
: "${TUIC_PORT:=443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${RUST_LOG:=warn}"

# 随机凭据（可预先导出 TUIC_UUID/TUIC_PASS 覆盖）
: "${TUIC_UUID:=$(uuidgen)}"
: "${TUIC_PASS:=$(openssl rand -hex 16)}"

# ========= 基础依赖（两种路径都需要）=========
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends curl jq ca-certificates uuid-runtime openssl iproute2

# ========= 证书自检 =========
[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

# ========= 运行用户与目录 =========
getent group tuic >/dev/null || groupadd --system tuic
id -u tuic >/dev/null 2>&1 || useradd --system -g tuic -M -d /var/lib/tuic -s /usr/sbin/nologin tuic
install -d -o tuic -g tuic -m 750 /var/lib/tuic
install -d -o root -g tuic -m 750 /etc/tuic

# ========= rust/cargo 工具链（仅在选择编译时才装）=========
ensure_cargo_toolchain() {
  apt install -y --no-install-recommends git build-essential pkg-config xz-utils
  if ! command -v cargo >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  fi
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  export PATH="$HOME/.cargo/bin:$PATH"
  # 避免个别环境 libgit2 TLS 问题
  export CARGO_NET_GIT_FETCH_WITH_CLI="${CARGO_NET_GIT_FETCH_WITH_CLI:-true}"
  export GIT_TERMINAL_PROMPT=0
}

# ========= 获取 main 最新提交（可选走 GITHUB_TOKEN）=========
get_head_sha_main() {
  local api="https://api.github.com/repos/Itsusinn/tuic/commits/main"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$api" | jq -r .sha
  else
    curl -fsSL "$api" | jq -r .sha
  fi
}

# ========= 方案 A：从源码编译（cargo）=========
install_tuic_cargo() {
  ensure_cargo_toolchain
  local sha; sha="$(get_head_sha_main)"
  [ -n "$sha" ] || { echo "无法获取 tuic main 的最新提交"; exit 1; }
  echo "[*] cargo 安装 tuic-server @ ${sha}（按 Cargo.toml 解析最新兼容依赖）"

  set +e
  # 关键点：显式包名写在命令末尾（最兼容），不使用 -p
  cargo install --git https://github.com/Itsusinn/tuic.git --rev "$sha" tuic-server --locked --force
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "[!] --locked 失败，回退不带 --locked（仍固定到该提交）"
    cargo install --git https://github.com/Itsusinn/tuic.git --rev "$sha" tuic-server --force
    rc=$?
  fi
  set -e
  [ $rc -eq 0 ] || { echo "cargo 安装失败"; exit 1; }

  install -m 0755 "$HOME/.cargo/bin/tuic-server" /usr/local/bin/tuic-server
  echo "== Built tuic-server @ ${sha} =="
}

# ========= 方案 B：下载最新 release 二进制 =========
install_tuic_release() {
  local json latest_tag arch asset alt url tmpd bin
  json="$(curl -fsSL https://api.github.com/repos/Itsusinn/tuic/releases/latest)"
  latest_tag="$(echo "$json" | jq -r '.tag_name // empty')"
  [ -n "$latest_tag" ] || { echo "GitHub API error (no latest tag)"; exit 1; }

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  asset="tuic-server-x86_64-linux";  alt="tuic-server-x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) asset="tuic-server-aarch64-linux"; alt="tuic-server-aarch64-unknown-linux-gnu" ;;
    *) echo "unsupported arch: $arch"; exit 1 ;;
  esac

  tmpd="$(mktemp -d)"; trap 't="${tmpd-}"; [ -n "$t" ] && rm -rf -- "$t"' RETURN
  url="https://github.com/Itsusinn/tuic/releases/latest/download/${asset}"
  if ! curl -fsSL --retry 3 --retry-delay 1 -o "$tmpd/tuic-server" "$url"; then
    echo "[!] 主资产失败，尝试回退 $alt"
    url="https://github.com/Itsusinn/tuic/releases/latest/download/${alt}"
    curl -fsSL --retry 3 --retry-delay 1 -o "$tmpd/tuic-server" "$url" || { echo "❌ 两个资产都失败"; exit 1; }
  fi
  install -m 0755 "$tmpd/tuic-server" /usr/local/bin/tuic-server
  trap - RETURN
  echo "== Installed tuic-server ${latest_tag} binary =="
}

# ========= 交互选择安装路径（默认 N=release）=========
echo
while :; do
  read -rp "是否用 cargo 从源码编译 tuic-server（每次都编 main 最新）？[y/N] " ans
  ans="${ans:-N}"
  case "$ans" in
    [Yy]) use_cargo=1; break ;;
    [Nn]) use_cargo=0; break ;;
    *) echo "只接受 y/N（回车默认 N）。";;
  esac
done

if [ "${use_cargo}" -eq 1 ]; then
  install_tuic_cargo
else
  install_tuic_release
fi

# ========= 首次生成配置（存在则不覆盖）=========
if [ ! -f /etc/tuic/config.json ]; then
  cat >/etc/tuic/config.json <<EOF
{
  "server": "[::]:${TUIC_PORT}",
  "users": { "${TUIC_UUID}": "${TUIC_PASS}" },
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

  "log_level": "${RUST_LOG}"
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

# ========= 启动 / 重载 =========
systemctl daemon-reload
systemctl enable --now tuic-server || true
systemctl try-reload-or-restart tuic-server || systemctl restart tuic-server

# ========= 摘要 =========
echo
/usr/local/bin/tuic-server -V 2>/dev/null || /usr/local/bin/tuic-server --version 2>/dev/null || true
echo
echo "UDP/${TUIC_PORT} 监听检查"
ss -Hnplu | grep -E ":${TUIC_PORT}([^0-9]|$)" || echo "未见 UDP/${TUIC_PORT} 监听/占用"
