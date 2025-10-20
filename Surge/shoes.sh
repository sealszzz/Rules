bash -c '
set -euo pipefail

# ===== 0) 依赖与证书自检 =====
apt update
apt install -y curl jq ca-certificates uuid-runtime openssl tar xz-utils

[ -f /etc/tls/cert.pem ] || { echo "MISSING /etc/tls/cert.pem"; exit 1; }
[ -f /etc/tls/key.pem ]  || { echo "MISSING /etc/tls/key.pem";  exit 1; }

# ===== 1) 系统用户与目录 =====
getent group shoes >/dev/null || groupadd --system shoes
id -u shoes >/dev/null 2>&1 || useradd --system -g shoes shoes
install -d -o shoes -g shoes -m 750 /etc/shoes

# ===== 2) 选择并安装二进制（GNU 优先，必要时回退 musl）=====
json="$(curl -fsSL https://api.github.com/repos/cfal/shoes/releases/latest)"
tag="$(echo "$json" | jq -r ".tag_name")"
assets="$(echo "$json" | jq -r ".assets[].name")"

pick_asset() {
  # 尝试 GNU
  echo "$assets" | grep -i -E "x86_64.*(linux|unknown-linux).*gnu.*(\.tar\.gz|\.zip)$" | head -n1 || true
}

asset="$(pick_asset)"
# 若未找到 GNU，则回退 musl
[ -n "$asset" ] || asset="$(echo "$assets" | grep -i -E "x86_64.*(linux|unknown-linux).*musl.*(\.tar\.gz|\.zip)$" | head -n1 || true)"
[ -n "$asset" ] || { echo "no suitable release asset"; exit 1; }

url="$(echo "$json" | jq -r ".assets[] | select(.name==\"$asset\") | .browser_download_url")"
echo "Using asset: $asset (tag: $tag)"

tmpd="$(mktemp -d)"; trap "rm -rf \"$tmpd\"" EXIT
curl -fL "$url" -o "$tmpd/pkg"

mkdir -p "$tmpd/unpack"
case "$asset" in
  *.tar.gz) tar -xzf "$tmpd/pkg" -C "$tmpd/unpack" ;;
  *.zip) apt-get install -y unzip >/dev/null 2>&1 || true; unzip -o "$tmpd/pkg" -d "$tmpd/unpack" ;;
  *) echo "unknown archive: $asset"; exit 1 ;;
esac

binpath="$(find "$tmpd/unpack" -maxdepth 3 -type f -name shoes -perm -u+x | head -n1)"
[ -n "$binpath" ] || { echo "shoes binary not found in archive"; exit 1; }

# 备份旧二进制
if [ -x /usr/local/bin/shoes ]; then
  cp -a /usr/local/bin/shoes "/usr/local/bin/shoes.bak.$(date +%Y%m%d%H%M%S)"
fi
install -m 0755 "$binpath" /usr/local/bin/shoes

# 记录已装版本（避免依赖 --version）
install -d -m 755 -o shoes -g shoes /etc/shoes
echo "$tag" > /etc/shoes/.installed_tag
chown shoes:shoes /etc/shoes/.installed_tag

# ===== 3) 默认配置（首次安装才生成；已有就跳过）=====
if [ ! -f /etc/shoes/config.yml ]; then
  UUID="$(uuidgen)"
  PASS="$(openssl rand -hex 16)"
  cat >/etc/shoes/config.yml <<EOF
- address: "[::]:8443"
  transport: quic
  quic_settings:
    cert: "/etc/tls/cert.pem"
    key:  "/etc/tls/key.pem"
    alpn: ["h3"]
    congestion_control: bbr
  protocol:
    type: tuic
    uuid: "$UUID"
    password: "$PASS"
EOF
  chown shoes:shoes /etc/shoes/config.yml
  chmod 640 /etc/shoes/config.yml
  echo "TUIC UUID: $UUID"
  echo "TUIC PASS: $PASS"
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
ExecStart=/usr/local/bin/shoes -c /etc/shoes/config.yml
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
echo "=== UDP:8443 ==="
ss -u -lpn | grep ":8443 " || echo "no UDP/8443 listener (check: journalctl -u shoes -e)"

# ===== 6) 安装升级脚本（只在远端 tag 变更时升级）=====
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
asset="\$(echo "\$assets" | grep -i -E "x86_64.*(linux|unknown-linux).*gnu.*(\\.tar\\.gz|\\.zip)$" | head -n1 || true)"
[ -n "\$asset" ] || asset="\$(echo "\$assets" | grep -i -E "x86_64.*(linux|unknown-linux).*musl.*(\\.tar\\.gz|\\.zip)$" | head -n1 || true)"
[ -n "\$asset" ] || { echo "no suitable release asset"; exit 1; }
url="\$(echo "\$json" | jq -r ".assets[] | select(.name==\"\$asset\") | .browser_download_url")"
echo "Upgrading to \$tag using \$asset ..."
tmpd="\$(mktemp -d)"; trap "rm -rf \"\$tmpd\"" EXIT
curl -fL "\$url" -o "\$tmpd/pkg"
mkdir -p "\$tmpd/unpack"
case "\$asset" in
  *.tar.gz) tar -xzf "\$tmpd/pkg" -C "\$tmpd/unpack" ;;
  *.zip) unzip -o "\$tmpd/pkg" -d "\$tmpd/unpack" ;;
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
