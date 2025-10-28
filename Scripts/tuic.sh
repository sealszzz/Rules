#!/usr/bin/env bash
# TUIC server 安装脚本（与 shoes 脚本同理念：A 源码=最新提交；B 二进制=最新 release）
# Debian/Ubuntu，需 root。2c2g 可用。不会清理依赖/老版本。
set -euo pipefail

# ========= 可调参数（可用环境变量覆盖）=========
: "${TUIC_PORT:=443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${RUST_LOG:=warn}"                     # 仅 systemd 环境变量传给 tuic-server
: "${TUIC_CONF:=/etc/tuic/config.json}"   # 也可改成 .json5
: "${GITHUB_TOKEN:=}"                     # 可选：用于 GitHub API 提升速率
: "${CARGO_NET_GIT_FETCH_WITH_CLI:=true}" # 让 cargo 用 git CLI 拉仓库，穿代理/鉴权更稳

# 随机凭据（可预先导出 TUIC_UUID/TUIC_PASS 覆盖）
: "${TUIC_UUID:=$(uuidgen)}"
: "${TUIC_PASS:=$(openssl rand -hex 16)}"

# ========= 基础依赖 =========
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends \
  curl jq ca-certificates uuid-runtime openssl iproute2

# ========= 证书自检 =========
[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

# ========= 运行用户与目录 =========
getent group tuic >/dev/null || groupadd --system tuic
id -u tuic  >/dev/null 2>&1 || useradd --system -g tuic -M -d /var/lib/tuic -s /usr/sbin/nologin tuic
install -d -o tuic -g tuic -m 750 /var/lib/tuic
install -d -o root -g tuic -m 750 /etc/tuic

# ========= 小工具 =========
_auth_hdr() {
  # 若提供 GITHUB_TOKEN 则附上鉴权头避免 API 限频；没提供就返回空
  [ -n "${GITHUB_TOKEN:-}" ] && printf 'Authorization: Bearer %s' "$GITHUB_TOKEN" || true
}

ensure_cargo_toolchain() {
  apt install -y --no-install-recommends git build-essential pkg-config xz-utils
  if ! command -v cargo >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 1 https://sh.rustup.rs | sh -s -- -y --profile minimal
  fi
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  export PATH="$HOME/.cargo/bin:$PATH"
  export CARGO_NET_GIT_FETCH_WITH_CLI="${CARGO_NET_GIT_FETCH_WITH_CLI}"
}

get_head_sha_main() {
  # 优先 API 读 main 分支 HEAD；失败则回退 git ls-remote（对付 API 封/限）
  local sha=""
  sha="$(
    curl -fsSL --retry 3 --retry-delay 1 \
      -H 'Accept: application/vnd.github+json' \
      ${GITHUB_TOKEN:+-H "$(_auth_hdr)"} \
      'https://api.github.com/repos/Itsusinn/tuic/commits/main' \
      | jq -r '.sha // empty' 2>/dev/null
  )" || true
  if [ -z "$sha" ]; then
    sha="$(git ls-remote https://github.com/Itsusinn/tuic.git main 2>/dev/null | awk '{print $1; exit}')" || true
  fi
  [ -n "$sha" ] && echo "$sha" || return 1
}

install_tuic_from_release() {
  # 通过 /releases/latest 自动挑选与你架构匹配的资产（偏好 gnu，其次 musl；包形态全兼容）
  local api json arch pat asset url tmpd binpath
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  pat="(x86_64|amd64).*(linux|unknown-linux).*";;
    aarch64|arm64) pat="(aarch64|arm64).*(linux|unknown-linux).*";;
    *) echo "unsupported arch: $arch"; return 1;;
  esac

  api='https://api.github.com/repos/Itsusinn/tuic/releases/latest'
  json="$(
    curl -fsSL --retry 3 --retry-delay 1 \
      -H 'Accept: application/vnd.github+json' \
      ${GITHUB_TOKEN:+-H "$(_auth_hdr)"} \
      "$api"
  )" || { echo "GitHub API error (releases/latest)"; return 1; }

  # 先偏好 gnu，再 musl；支持 .tar.gz/.tar.xz/.zip/裸二进制
  asset="$(
    echo "$json" | jq -r '.assets[].name' | \
      grep -iE "^tuic-server-.*${pat}gnu.*(\.tar\.(gz|xz)|\.zip|$)" | head -n1
  )" || true
  [ -n "$asset" ] || asset="$(
    echo "$json" | jq -r '.assets[].name' | \
      grep -iE "^tuic-server-.*${pat}musl.*(\.tar\.(gz|xz)|\.zip|$)" | head -n1
  )" || true
  [ -n "$asset" ] || { echo "no suitable release asset for $arch"; return 1; }

  url="$(echo "$json" | jq -r ".assets[] | select(.name==\"$asset\") | .browser_download_url")"
  echo "[*] Installing TUIC via asset: $asset"

  tmpd="$(mktemp -d)"; trap 't="${tmpd-}"; [ -n "$t" ] && rm -rf -- "$t"' RETURN
  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg" "$url"

  mkdir -p "$tmpd/unpack"
  case "$asset" in
    *.tar.gz) tar -xzf "$tmpd/pkg" -C "$tmpd/unpack" ;;
    *.tar.xz) tar -xJf "$tmpd/pkg" -C "$tmpd/unpack" ;;
    *.zip)    unzip -q "$tmpd/pkg" -d "$tmpd/unpack" ;;
    *)        cp -f "$tmpd/pkg" "$tmpd/unpack/tuic-server" ;;
  esac

  binpath="$(find "$tmpd/unpack" -maxdepth 3 -type f -name tuic-server -perm -u+x | head -n1)"
  [ -n "$binpath" ] || { echo "tuic-server binary not found in asset"; return 1; }
  install -m 0755 "$binpath" /usr/local/bin/tuic-server
  trap - RETURN
}

install_tuic_from_cargo() {
  ensure_cargo_toolchain
  local sha; sha="$(get_head_sha_main)" || { echo "无法获取 Itsusinn/tuic main 的最新提交"; exit 1; }
  echo "[*] cargo 安装 tuic-server @ $sha（按 Cargo.toml 解析最新兼容依赖）"
  # -p 指定工作区内具体包，--rev 固定到 main 的 HEAD 提交；先尝试 --locked，失败再退不锁定
  set +e
  cargo install --git https://github.com/Itsusinn/tuic.git --rev "$sha" -p tuic-server --locked --force
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "[!] --locked 失败，回退不带 --locked（仍然固定到该提交）"
    cargo install --git https://github.com/Itsusinn/tuic.git --rev "$sha" -p tuic-server --force
    rc=$?
  fi
  set -e
  [ $rc -eq 0 ] || { echo "cargo 安装失败"; exit 1; }
  install -m 0755 "$HOME/.cargo/bin/tuic-server" /usr/local/bin/tuic-server
  echo "== Built tuic-server @ ${sha} =="
}

# ========= 交互选择安装方式（默认 N：Release 二进制；y/Y：cargo 源码）=========
USE_CARGO=0
read -rp "使用 cargo 源码编译安装 tuic-server（每次都编译 main 的最新提交）？[y/N] " _ans || true
case "${_ans:-}" in y|Y) USE_CARGO=1;; esac

if [ "$USE_CARGO" -eq 1 ]; then
  install_tuic_from_cargo
else
  install_tuic_from_release || { echo "[!] release 路径失败，回退到 cargo 构建"; install_tuic_from_cargo; }
fi

# ========= 首次生成配置（存在则不覆盖）=========
if [ ! -f "$TUIC_CONF" ]; then
  install -d -o root -g tuic -m 750 "$(dirname "$TUIC_CONF")"
  cat >"$TUIC_CONF" <<EOF
{
  "server": "[::]:${TUIC_PORT}",
  "users": {
    "${TUIC_UUID}": "${TUIC_PASS}"
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
  chown root:tuic "$TUIC_CONF"
  chmod 640      "$TUIC_CONF"

  echo "TUIC UUID: ${TUIC_UUID}"
  echo "TUIC PASS: ${TUIC_PASS}"
fi

# ========= systemd =========
if [ ! -f /etc/systemd/system/tuic-server.service ]; then
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
ExecStart=/usr/local/bin/tuic-server -c ${TUIC_CONF}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s
Environment=RUST_LOG=${RUST_LOG}

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
/usr/local/bin/tuic-server -V 2>/dev/null || /usr/local/bin/tuic-server --version 2>/dev/null || true
echo
echo "UDP/${TUIC_PORT} 监听检查（注意与其它 QUIC/HTTP3 冲突）"
ss -Hnplu | grep -E ":${TUIC_PORT}([^0-9]|$)" || echo "未见 UDP/${TUIC_PORT} 监听/占用"
