#!/usr/bin/env bash
set -euo pipefail

# ===== 0) 基础依赖（编译 Rust & 生成账户用）=====
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends \
  curl ca-certificates git build-essential pkg-config uuid-runtime openssl jq iproute2

# ===== 1) 安装 rustup/cargo（若尚未安装）=====
if ! command -v cargo >/dev/null 2>&1; then
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
# 加载 cargo 环境（root 环境下安装）
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
export PATH="$HOME/.cargo/bin:$PATH"

# ===== 2) 用 cargo 从仓库默认分支安装/更新 Shoes =====
repo="https://github.com/cfal/shoes"
default_branch="$(curl -fsSL https://api.github.com/repos/cfal/shoes | jq -r .default_branch 2>/dev/null || true)"
# 取不到分支名时保底用 master（避免 API 限频/异常导致安装失败）
if [ -z "${default_branch:-}" ] || [ "${default_branch}" = "null" ]; then
  default_branch="master"
fi

# 强制装到最新提交（避免缓存不更新），优先 --locked
set +e
cargo install --git "$repo" --branch "$default_branch" --locked --force
rc=$?
if [ $rc -ne 0 ]; then
  cargo install --git "$repo" --branch "$default_branch" --force
  rc=$?
fi
set -e
if [ $rc -ne 0 ]; then
  echo "cargo install shoes 失败（分支：$default_branch）" >&2
  exit 1
fi

# 安装到 /usr/local/bin（systemd 更稳妥）
install -m 0755 "$HOME/.cargo/bin/shoes" /usr/local/bin/shoes

# ===== 3) 首次准备用户与目录 =====
getent group shoes >/dev/null || groupadd --system shoes
id -u shoes >/dev/null 2>&1 || useradd --system -g shoes -M -d /var/lib/shoes -s /usr/sbin/nologin shoes
install -d -o shoes -g shoes -m 750 /var/lib/shoes
install -d -o root  -g shoes -m 750 /etc/shoes

# ===== 4) 首次生成最小配置（之后不改你的配置）=====
if [ ! -f /etc/shoes/config.yml ]; then
  T_UUID="$(uuidgen)"
  T_PASS="$(openssl rand -hex 16)"
  H_PASS="$(openssl rand -hex 16)"
  cat >/etc/shoes/config.yml <<'EOF'
- address: "[::]:443"
  transport: quic
  quic_settings:
    cert: "/etc/tls/cert.pem"
    key:  "/etc/tls/key.pem"
    alpn_protocols: ["h3"]
    congestion_control: bbr
  protocol:
    type: tuic
    uuid: "__T_UUID__"
    password: "__T_PASS__"

- address: "[::]:8443"
  transport: quic
  quic_settings:
    cert: "/etc/tls/cert.pem"
    key:  "/etc/tls/key.pem"
    alpn_protocols: ["h3"]
    congestion_control: bbr
  protocol:
    type: hysteria2
    password: "__H_PASS__"

  rules:
    - allow-all-direct
EOF
  sed -i "s#__T_UUID__#${T_UUID}#g; s#__T_PASS__#${T_PASS}#g; s#__H_PASS__#${H_PASS}#g" /etc/shoes/config.yml

  chown root:shoes /etc/shoes/config.yml
  chmod 640      /etc/shoes/config.yml
  echo "TUIC UUID: $T_UUID"
  echo "TUIC PASS: $T_PASS"
  echo "HY2  PASS: $H_PASS"
fi

# ===== 5) systemd 服务（首次创建；之后只重载/重启）=====
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
  systemctl daemon-reload
  systemctl enable --now shoes
else
  systemctl try-reload-or-restart shoes || systemctl restart shoes
fi

# ===== 6) 摘要 =====
echo "== shoes version: $(/usr/local/bin/shoes -V 2>/dev/null || echo unknown) =="
ss -Hnplu | grep -E ':(443|8443)\b' || true
