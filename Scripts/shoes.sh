bash -c '
set -euo pipefail

# ===== 0) 依赖与证书自检 =====
apt update
apt install -y curl jq ca-certificates uuid-runtime openssl tar xz-utils unzip

[ -f /etc/tls/cert.pem ] || { echo "MISSING /etc/tls/cert.pem"; exit 1; }
[ -f /etc/tls/key.pem ]  || { echo "MISSING /etc/tls/key.pem";  exit 1; }

# ===== 1) 系统用户与目录（/etc 配置，/var/lib 工作目录）=====
getent group shoes >/dev/null || groupadd --system shoes
id -u shoes >/dev/null 2>&1 || useradd --system -g shoes -M -d /var/lib/shoes -s /usr/sbin/nologin shoes

install -d -o shoes -g shoes -m 750 /var/lib/shoes
install -d -o root  -g shoes -m 750 /etc/shoes

# ===== 2) 选择并安装二进制（优先 GNU，其次 musl；支持 x86_64 & aarch64）=====
json="$(curl -fsSL https://api.github.com/repos/cfal/shoes/releases/latest)"
tag="$(echo "$json" | jq -r ".tag_name")"
assets="$(echo "$json" | jq -r ".assets[].name")"

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)   pat_arch="(x86_64|amd64)" ;;
  aarch64|arm64)  pat_arch="(aarch64|arm64)" ;;
  *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac

pick_asset() {
  # 先挑 GNU，再尝试 musl
  echo "$assets" | grep -i -E "${pat_arch}.*(linux|unknown-linux).*gnu.*(\.tar\.gz|\.zip)$" | head -n1 || true
}

asset="$(pick_asset)"
[ -n "$asset" ] || asset="$(echo "$assets" | grep -i -E "${pat_arch}.*(linux|unknown-linux).*musl.*(\.tar\.gz|\.zip)$" | head -n1 || true)"
[ -n "$asset" ] || { echo "no suitable release asset"; exit 1; }

url="$(echo "$json" | jq -r ".assets[] | select(.name==\"$asset\") | .browser_download_url")"
echo "Using asset: $asset (tag: $tag)"

tmpd="$(mktemp -d)"; trap "rm -rf \"$tmpd\"" EXIT
curl -fL "$url" -o "$tmpd/pkg"

mkdir -p "$tmpd/unpack"
case "$asset" in
  *.tar.gz) tar -xzf "$tmpd/pkg" -C "$tmpd/unpack" ;;
  *.zip)    unzip -o "$tmpd/pkg" -d "$tmpd/unpack" >/dev/null ;;
  *) echo "unknown archive: $asset"; exit 1 ;;
esac

binpath="$(find "$tmpd/unpack" -maxdepth 3 -type f -name shoes -perm -u+x | head -n1)"
[ -n "$binpath" ] || { echo "shoes binary not found in archive"; exit 1; }

# 记录已装版本
echo "$tag" > /etc/shoes/.installed_tag
chown shoes:shoes /etc/shoes/.installed_tag

# ===== 3) 默认配置（首次安装生成；已有则保留）=====
if [ ! -f /etc/shoes/config.yml ]; then
  # TUIC 账户
  T_UUID="$(uuidgen)"
  T_PASS="$(openssl rand -hex 16)"
  # HY2 账户
  H_PASS="$(openssl rand -hex 16)"

  cat >/etc/shoes/config.yml <<EOF
# Shoes 服务配置（同时启用 TUIC 与 Hysteria2）
# - TUIC 监听 UDP/443
# - Hysteria2 监听 UDP/8443
# 证书由 /etc/tls/cert.pem /etc/tls/key.pem 提供
- address: "[::]:443"
  transport: quic
  quic_settings:
    cert: "/etc/tls/cert.pem"
    key:  "/etc/tls/key.pem"
    alpn_protocols: ["h3"]
    congestion_control: bbr
  protocol:
    type: tuic
    uuid: "$T_UUID"
    password: "$T_PASS"

- address: "[::]:8443"
  transport: quic
  quic_settings:
    cert: "/etc/tls/cert.pem"
    key:  "/etc/tls/key.pem"
    alpn_protocols: ["h3"]
    congestion_control: bbr
  protocol:
    type: hysteria2
    password: "$H_PASS"
  rules:
    - allow-all-direct
EOF

  chown root:shoes /etc/shoes/config.yml
  chmod 640      /etc/shoes/config.yml

  echo "TUIC  UUID: $T_UUID"
  echo "TUIC  PASS: $T_PASS"
  echo "HY2   PASS: $H_PASS"
else
  echo "Existing /etc/shoes/config.yml detected; keep it."
fi

# ===== 4) systemd 单元 =====
cat >/etc/systemd/system/shoes.service <<EOF
[Unit]
Description=Shoes Server
Documentation=https://github.com/cfal/shoes
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

[Install]
WantedBy=multi-user.target
EOF

# ===== 5) 干跑校验 + 启动 =====
/usr/local/bin/shoes -d /etc/shoes/config.yml
systemctl daemon-reload
systemctl enable --now shoes

sleep 1
echo "=== status ==="
systemctl --no-pager --full status shoes || true
echo "=== UDP listeners ==="
ss -u -lpn | grep -E ":443 |:8443 " || echo "no UDP/443 or 8443 listener (check: journalctl -u shoes -e)"

# ===== 6) 升级脚本（仅在新 tag 出现时动作；含架构挑选）=====
cat >/usr/local/sbin/shoes-update <<EOF
#!/usr/bin/env bash
set -euo pipefail
json="\$(curl -fsSL https://api.github.com/repos/cfal/shoes/releases/latest)"
tag="\$(echo "\$json" | jq -r ".tag_name")"
inst="/etc/shoes/.installed_tag"
if [ -f "\$inst" ] && [ "\$(cat "\$inst")" = "\$tag" ]; then
  echo "shoes is up-to-date (\$tag)"
  exit 0
fi
assets="\$(echo "\$json" | jq -r ".assets[].name")"
arch="\$(uname -m)"
case "\$arch" in
  x86_64|amd64) pat_arch="(x86_64|amd64)";;
  aarch64|arm64) pat_arch="(aarch64|arm64)";;
  *) echo "unsupported arch: \$arch" >&2; exit 1;;
esac
asset="\$(echo "\$assets" | grep -i -E "\${pat_arch}.*(linux|unknown-linux).*gnu.*(\\.tar\\.gz|\\.zip)\$" | head -n1 || true)"
[ -n "\$asset" ] || asset="\$(echo "\$assets" | grep -i -E "\${pat_arch}.*(linux|unknown-linux).*musl.*(\\.tar\\.gz|\\.zip)\$" | head -n1 || true)"
[ -n "\$asset" ] || { echo "no suitable release asset"; exit 1; }
url="\$(echo "\$json" | jq -r ".assets[] | select(.name==\"\$asset\") | .browser_download_url")"
echo "Upgrading to \$tag using \$asset ..."
tmpd="\$(mktemp -d)"; trap "rm -rf \"\$tmpd\"" EXIT
curl -fL "\$url" -o "\$tmpd/pkg"
mkdir -p "\$tmpd/unpack"
case "\$asset" in
  *.tar.gz) tar -xzf "\$tmpd/pkg" -C "\$tmpd/unpack" ;;
  *.zip)    unzip -o "\$tmpd/pkg" -d "\$tmpd/unpack" >/dev/null ;;
  *) echo "unknown archive: \$asset"; exit 1 ;;
esac
binpath="\$(find "\$tmpd/unpack" -maxdepth 3 -type f -name shoes -perm -u+x | head -n1)"
[ -n "\$binpath" ] || { echo "shoes binary not found in archive"; exit 1; }
cp -a /usr/local/bin/shoes "/usr/local/bin/shoes.bak.\$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
install -m 0755 "\$binpath" /usr/local/bin/shoes
echo "\$tag" > "\$inst"
systemctl try-reload-or-restart shoes 2>/dev/null || true
echo "Done. Installed tag: \$tag"
EOF
chmod +x /usr/local/sbin/shoes-update
echo "Hint: run shoes-update later to upgrade only when a new release appears."
'
