#!/usr/bin/env bash
set -euo pipefail

# ========= 可调参数（可用环境变量覆盖）=========
: "${TUIC_PORT:=4443}"
: "${HY2_PORT:=8443}"
: "${RUST_LOG:=warn}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

# 随机凭据（可预先导出 T_UUID/T_PASS/H_PASS 覆盖）
: "${T_UUID:=$(uuidgen)}"
: "${T_PASS:=$(openssl rand -hex 16)}"
: "${H_PASS:=$(openssl rand -base64 18 | tr -d '\n')}"

# ========= 基础依赖（两种路径都需要）=========
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends \
  curl jq ca-certificates tar unzip xz-utils uuid-runtime openssl iproute2

# ========= 证书自检 =========
[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

# ========= 用户与目录 =========
getent group shoes >/dev/null || groupadd --system shoes
id -u shoes  >/dev/null 2>&1 || useradd --system -g shoes -M -d /var/lib/shoes -s /usr/sbin/nologin shoes
install -d -o shoes -g shoes -m 750 /var/lib/shoes
install -d -o root  -g shoes -m 750 /etc/shoes

# ========= 只在选 cargo 时才装构建链 =========
ensure_cargo_toolchain() {
  apt install -y --no-install-recommends \
    git build-essential pkg-config cmake clang llvm-dev libclang-dev

  if ! command -v cargo >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  fi
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  export PATH="$HOME/.cargo/bin:$PATH"

  # 某些环境下避免 cargo 内置 git 受限
  export CARGO_NET_GIT_FETCH_WITH_CLI=true
}

# ========= 方案 A：从源码编译（cargo，固定到 master 最新 SHA + 最新兼容依赖）=========
install_shoes_cargo() {
  ensure_cargo_toolchain

  # 优先 GitHub API（若存在 GITHUB_TOKEN 自动使用），失败则 git 原生兜底
  local sha=""
  if [ -n "${GITHUB_TOKEN-}" ]; then
    sha="$(curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            https://api.github.com/repos/cfal/shoes/commits/master \
            | jq -r '.sha // empty' || true)"
  else
    sha="$(curl -fsSL https://api.github.com/repos/cfal/shoes/commits/master \
            | jq -r '.sha // empty' || true)"
  fi

  if [ -z "$sha" ]; then
    sha="$(git ls-remote https://github.com/cfal/shoes master 2>/dev/null | awk '{print $1}')" || true
  fi

  [ -n "$sha" ] || { echo "无法获取 shoes/master 最新提交（API 与 git 皆失败）"; exit 1; }

  # 不加 --locked => 依赖按 Cargo.toml 解析为“最新兼容”
  cargo install --git https://github.com/cfal/shoes --rev "$sha" --force
  install -m 0755 "$HOME/.cargo/bin/shoes" /usr/local/bin/shoes
  echo "== Built shoes @ ${sha} (HEAD of master), deps = latest allowed by Cargo.toml =="
}

# ========= 方案 B：下载最新 release 二进制 =========
install_shoes_release() {
  local json latest_tag assets asset url pat_arch arch tmpd binpath

  json="$(curl -fsSL https://api.github.com/repos/cfal/shoes/releases/latest)"
  latest_tag="$(echo "$json" | jq -r '.tag_name // empty')"
  [ -n "$latest_tag" ] || { echo "GitHub API error (no latest tag)"; exit 1; }

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  pat_arch="(x86_64|amd64)";;
    aarch64|arm64) pat_arch="(aarch64|arm64)";;
    *) echo "unsupported arch: $arch"; exit 1;;
  esac

  assets="$(echo "$json" | jq -r '.assets[].name')"
  # 偏好 gnu，失败再尝试 musl；支持 .tar.gz/.tar.xz/.zip
  asset="$(echo "$assets" | grep -i -E "${pat_arch}.*(linux|unknown-linux).*gnu.*(\.tar\.(gz|xz)|\.zip)$" | head -n1 || true)"
  [ -n "$asset" ] || asset="$(echo "$assets" | grep -i -E "${pat_arch}.*(linux|unknown-linux).*musl.*(\.tar\.(gz|xz)|\.zip)$" | head -n1 || true)"
  [ -n "$asset" ] || { echo "no suitable release asset"; exit 1; }

  url="$(echo "$json" | jq -r ".assets[] | select(.name==\"$asset\") | .browser_download_url")"
  echo "[*] Installing Shoes $latest_tag via asset: $asset"

  local tmpd; tmpd="$(mktemp -d)"
  # 函数返回即清理 tmpd；兼容 set -u
  trap 't="${tmpd-}"; [ -n "$t" ] && rm -rf -- "$t"' RETURN

  curl -fL "$url" -o "$tmpd/pkg"
  mkdir -p "$tmpd/unpack"
  case "$asset" in
    *.tar.gz) tar -xzf "$tmpd/pkg" -C "$tmpd/unpack" ;;
    *.tar.xz) tar -xJf "$tmpd/pkg" -C "$tmpd/unpack" ;;
    *.zip)    unzip -q  "$tmpd/pkg" -d "$tmpd/unpack" ;;
  esac

  binpath="$(find "$tmpd/unpack" -maxdepth 3 -type f -name shoes -perm -u+x | head -n1)"
  [ -n "$binpath" ] || { echo "shoes binary not found in asset"; exit 1; }

  install -m 0755 "$binpath" /usr/local/bin/shoes

  # 清掉本函数的 RETURN trap，防止后续函数也触发
  trap - RETURN
}

# ========= 交互选择安装路径（默认 N=release；给默认值以防 stdin 异常）=========
echo
use_cargo=0
while :; do
  read -rp "是否用 cargo 从源码编译 Shoes？[y/N] " ans || { echo; break; }
  ans="${ans:-N}"
  case "$ans" in
    [Yy]) use_cargo=1; break ;;
    [Nn]) use_cargo=0; break ;;
    *) echo "只接受 y/N（回车默认 N）。";;
  esac
done

if [ "${use_cargo}" -eq 1 ]; then
  install_shoes_cargo
else
  install_shoes_release
fi

# ========= 首次生成配置（存在则不覆盖）=========
if [ ! -f /etc/shoes/config.yml ]; then
  cat >/etc/shoes/config.yml <<EOF
- address: "[::]:${TUIC_PORT}"
  transport: quic
  quic_settings:
    cert: "${CERT}"
    key:  "${KEY}"
    alpn_protocols: ["h3"]
    congestion_control: bbr
  protocol:
    type: tuic
    uuid: "${T_UUID}"
    password: "${T_PASS}"

- address: "[::]:${HY2_PORT}"
  transport: quic
  quic_settings:
    cert: "${CERT}"
    key:  "${KEY}"
    alpn_protocols: ["h3"]
    congestion_control: bbr
  protocol:
    type: hysteria2
    password: "${H_PASS}"

  rules:
    - allow-all-direct
EOF
  chown root:shoes /etc/shoes/config.yml
  chmod 640      /etc/shoes/config.yml

  echo "TUIC UUID: ${T_UUID}"
  echo "TUIC PASS: ${T_PASS}"
  echo "HY2  PASS: ${H_PASS}"
fi

# ========= systemd =========
if [ ! -f /etc/systemd/system/shoes.service ]; then
  cat >/etc/systemd/system/shoes.service <<EOF
[Unit]
Description=Shoes Server
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=shoes
Group=shoes
Type=simple
UMask=0077
WorkingDirectory=/var/lib/shoes
ExecStart=/usr/local/bin/shoes /etc/shoes/config.yml
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s
Environment=RUST_LOG=${RUST_LOG}

[Install]
WantedBy=multi-user.target
EOF
fi

# ========= 启动 / 重载 =========
systemctl daemon-reload
systemctl enable --now shoes || true
systemctl try-reload-or-restart shoes || systemctl restart shoes

# ========= 摘要 =========
echo
ver="$(
  /usr/local/bin/shoes -V 2>/dev/null \
  || /usr/local/bin/shoes --version 2>/dev/null \
  || true
)"
echo "== shoes version: ${ver:-unknown} =="
echo
echo "UDP 监听检查："
ss -Hnplu | grep -E ":${TUIC_PORT}([^0-9]|$)|:${HY2_PORT}([^0-9]|$)" || true
