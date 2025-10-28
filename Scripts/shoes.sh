#!/usr/bin/env bash
set -euo pipefail

# ========= 可调参数（可用环境变量覆盖）=========
: "${TUIC_PORT:=443}"
: "${HY2_PORT:=4443}"
: "${RUST_LOG:=warn}"   # shoes 的日志等级
CERT="/etc/tls/cert.pem"
KEY="/etc/tls/key.pem"

# 随机凭据（可预先导出 T_UUID/T_PASS/H_PASS 覆盖）
: "${T_UUID:=$(uuidgen)}"
: "${T_PASS:=$(openssl rand -hex 16)}"
: "${H_PASS:=$(openssl rand -base64 18 | tr -d '\n')}"

# ========= 依赖 =========
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends \
  curl jq ca-certificates tar unzip xz-utils uuid-runtime openssl iproute2

# ========= 证书自检 =========
[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

# ========= 获取 GitHub 最新发布并安装 =========
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
# 先偏好 gnu，再退 musl，再退 zip/tar 各种后缀
asset="$(echo "$assets" | grep -i -E "${pat_arch}.*(linux|unknown-linux).*gnu.*(\.tar\.(gz|xz)|\.zip)$" | head -n1 || true)"
[ -n "$asset" ] || asset="$(echo "$assets" | grep -i -E "${pat_arch}.*(linux|unknown-linux).*musl.*(\.tar\.(gz|xz)|\.zip)$" | head -n1 || true)"
[ -n "$asset" ] || { echo "no suitable release asset"; exit 1; }

url="$(echo "$json" | jq -r ".assets[] | select(.name==\"$asset\") | .browser_download_url")"
echo "[*] Installing Shoes $latest_tag via asset: $asset"

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
curl -fL "$url" -o "$tmpd/pkg"
mkdir -p "$tmpd/unpack"
case "$asset" in
  *.tar.gz) tar -xzf "$tmpd/pkg" -C "$tmpd/unpack" ;;
  *.tar.xz) tar -xJf "$tmpd/pkg" -C "$tmpd/unpack" ;;
  *.zip)    unzip -q  "$tmpd/pkg" -d "$tmpd/unpack" ;;
esac

binpath="$(find "$tmpd/unpack" -maxdepth 3 -type f -name shoes -perm -u+x | head -n1)"
[ -n "$binpath" ] || { echo "shoes binary not found in asset"; exit 1; }

# 安装到 /usr/local/bin
if [ -x /usr/local/bin/shoes ]; then
  cp -a /usr/local/bin/shoes "/usr/local/bin/shoes.bak.$(date +%Y%m%d%H%M%S)" || true
fi
install -m 0755 "$binpath" /usr/local/bin/shoes

# ========= 用户与目录 =========
getent group shoes >/dev/null || groupadd --system shoes
id -u shoes  >/dev/null 2>&1 || useradd --system -g shoes -M -d /var/lib/shoes -s /usr/sbin/nologin shoes
install -d -o shoes -g shoes -m 750 /var/lib/shoes
install -d -o root  -g shoes -m 750 /etc/shoes

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

# ========= systemd 单元（禁止变量展开）=========
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

# ========= 启动 / 重载 =========
systemctl daemon-reload
systemctl enable --now shoes || true
systemctl try-reload-or-restart shoes || systemctl restart shoes

# ========= 摘要 =========
echo
echo "== shoes version: $(/usr/local/bin/shoes -V 2>/dev/null || echo unknown) =="
echo
echo "UDP 监听检查："
ss -Hnplu | grep -E ":${TUIC_PORT} |:${HY2_PORT} " || true
