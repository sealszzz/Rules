#!/usr/bin/env bash
set -euo pipefail

# ========= Tunables (override via env) =========
: "${TUIC_PORT:=4443}"
: "${HY2_PORT:=8443}"
: "${RUST_LOG:=warn}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

# Random creds (override with T_UUID/T_PASS/H_PASS if desired)
: "${T_UUID:=$(uuidgen)}"
: "${T_PASS:=$(openssl rand -hex 16)}"
: "${H_PASS:=$(openssl rand -base64 18 | tr -d '\n')}"

export DEBIAN_FRONTEND=noninteractive

# ========= Base deps =========
apt update
apt install -y --no-install-recommends \
  curl jq ca-certificates tar unzip xz-utils uuid-runtime openssl iproute2

# ========= Cert check =========
[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

# ========= User & dirs =========
getent group shoes >/dev/null || groupadd --system shoes
id -u shoes  >/dev/null 2>&1 || useradd --system -g shoes -M -d /var/lib/shoes -s /usr/sbin/nologin shoes
install -d -o shoes -g shoes -m 750 /var/lib/shoes
install -d -o root  -g shoes -m 750 /etc/shoes

# ========= Optional cargo toolchain =========
ensure_cargo_toolchain() {
  apt install -y --no-install-recommends git build-essential pkg-config cmake clang llvm-dev libclang-dev
  if ! command -v cargo >/dev/null 2>&1; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  fi
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  export PATH="$HOME/.cargo/bin:$PATH"
  export CARGO_NET_GIT_FETCH_WITH_CLI=true
}

# ========= Build from source (cargo) =========
install_shoes_cargo() {
  ensure_cargo_toolchain

  # Prefer API (with optional token), fallback to git
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

  # GNU only (Cargo will target host toolchain; no musl)
  cargo install --git https://github.com/cfal/shoes --rev "$sha" --force
  install -m 0755 "$HOME/.cargo/bin/shoes" /usr/local/bin/shoes
  echo "== Built shoes @ ${sha} =="
}

# ========= Install latest release (no API; GNU only) =========
install_shoes_release() {
  case "$(uname -m)" in
    x86_64|amd64)  ASSET="shoes-x86_64-unknown-linux-gnu.tar.gz"  ;;
    aarch64|arm64) ASSET="shoes-aarch64-unknown-linux-gnu.tar.gz" ;;
    *) echo "unsupported arch: $(uname -m)（仅 x86_64 / aarch64）" >&2; exit 1 ;;
  esac

  local BASE="https://github.com/cfal/shoes/releases/latest/download"
  local tmpd; tmpd="$(mktemp -d)"
  trap 't="${tmpd-}"; [ -n "$t" ] && rm -rf -- "$t"' RETURN

  echo "[*] 下载 ${ASSET} ..."
  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.tgz" "${BASE}/${ASSET}"

  mkdir -p "$tmpd/unpack"
  tar -xzf "$tmpd/pkg.tgz" -C "$tmpd/unpack"

  local bin
  bin="$(find "$tmpd/unpack" -type f -name shoes -perm -u+x | head -n1 || true)"
  [ -n "$bin" ] || { echo "未在资产中找到可执行文件 shoes"; exit 1; }

  install -m 0755 "$bin" /usr/local/bin/shoes
  trap - RETURN
}

# ========= Choose install path (args/env/interactive; default: release) =========
use_cargo=0

# Args override
for arg in "${@:-}"; do
  case "$arg" in
    --cargo)   use_cargo=1 ;;
    --release) use_cargo=0 ;;
  esac
done

# Env override
if [ -n "${SHOES_INSTALL:-}" ]; then
  case "${SHOES_INSTALL}" in
    cargo|CARGO)     use_cargo=1 ;;
    release|RELEASE) use_cargo=0 ;;
  esac
fi

# Interactive prompt only if no args/env & TTY
if [ -t 0 ] && [ -z "${SHOES_INSTALL:-}" ] && ! printf '%s' "$*" | grep -qE -- '--(cargo|release)'; then
  printf '\n是否用 cargo 从源码编译 Shoes？[y/N] (默认 N): '
  read -r ans || ans=""
  case "${ans}" in
    [Yy]) use_cargo=1 ;;
    *)    use_cargo=0 ;;
  esac
fi

if [ "$use_cargo" -eq 1 ]; then
  echo "[选择] 使用 cargo 从源码编译"
  install_shoes_cargo
else
  echo "[选择] 使用 release 预编译二进制"
  install_shoes_release
fi

# ========= First-time config (idempotent) =========
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
  cat >/etc/systemd/system/shoes.service <<'EOF'
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
Environment=RUST_LOG=warn

[Install]
WantedBy=multi-user.target
EOF
fi

# ========= Start / Reload =========
systemctl daemon-reload
systemctl enable --now shoes || true
systemctl try-reload-or-restart shoes || systemctl restart shoes

# ========= Summary =========
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
