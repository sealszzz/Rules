bash -c '
set -euo pipefail

# ========== 依赖 ==========
apt update
apt install -y curl jq ca-certificates tar unzip uuid-runtime xxd

# ========== 获取 GitHub 最新发布 ==========
json="$(curl -fsSL https://api.github.com/repos/cfal/shoes/releases/latest)"
latest_tag="$(echo "$json" | jq -r ".tag_name")"
assets="$(echo "$json" | jq -r ".assets[].name")"

# ========== 已装版本（不写 tag 文件，直接读二进制）==========
installed_tag=""
if command -v /usr/local/bin/shoes >/dev/null 2>&1; then
  installed_tag="$(/usr/local/bin/shoes -V 2>/dev/null | sed -nE "s/.*(v?[0-9]+(\.[0-9]+){1,3}).*/\1/p" | head -n1 || true)"
fi
strip_v(){ printf "%s" "$1" | sed "s/^v//"; }

# ========== 如需则下载并安装 ==========
need_install=1
if [ -n "$installed_tag" ] && [ "$(strip_v "$installed_tag")" = "$(strip_v "$latest_tag")" ]; then
  need_install=0
  echo "shoes already up-to-date ($installed_tag)"
fi

if [ "$need_install" -eq 1 ]; then
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) pat_arch="(x86_64|amd64)";;
    aarch64|arm64) pat_arch="(aarch64|arm64)";;
    *) echo "unsupported arch: $arch" >&2; exit 1;;
  esac
  asset="$(echo "$assets" | grep -i -E "${pat_arch}.*(linux|unknown-linux).*gnu.*(\.tar\.gz|\.zip)$" | head -n1 || true)"
  [ -n "$asset" ] || asset="$(echo "$assets" | grep -i -E "${pat_arch}.*(linux|unknown-linux).*musl.*(\.tar\.gz|\.zip)$" | head -n1 || true)"
  [ -n "$asset" ] || { echo "no suitable release asset"; exit 1; }
  url="$(echo "$json" | jq -r ".assets[] | select(.name==\"$asset\") | .browser_download_url")"
  echo "Installing $latest_tag via $asset ..."
  tmpd="$(mktemp -d)"; trap "rm -rf \"$tmpd\"" EXIT
  curl -fL "$url" -o "$tmpd/pkg"
  mkdir -p "$tmpd/unpack"
  case "$asset" in
    *.tar.gz) tar -xzf "$tmpd/pkg" -C "$tmpd/unpack" ;;
    *.zip)    unzip -q  "$tmpd/pkg" -d "$tmpd/unpack" ;;
  esac
  binpath="$(find "$tmpd/unpack" -maxdepth 3 -type f -name shoes -perm -u+x | head -n1)"
  [ -n "$binpath" ] || { echo "shoes binary not found"; exit 1; }
  # 安装到 /usr/local/bin/shoes（备份老的）
  if [ -x /usr/local/bin/shoes ]; then
    cp -a /usr/local/bin/shoes "/usr/local/bin/shoes.bak.$(date +%Y%m%d%H%M%S)" || true
  fi
  install -m 0755 "$binpath" /usr/local/bin/shoes
fi

# ========== 首次：用户/目录 & 配置（之后不改配置）==========
getent group shoes >/dev/null || groupadd --system shoes
id -u shoes >/dev/null 2>&1 || useradd --system -g shoes -M -d /var/lib/shoes -s /usr/sbin/nologin shoes
install -d -o shoes -g shoes -m 750 /var/lib/shoes
install -d -o root  -g shoes -m 750 /etc/shoes

if [ ! -f /etc/shoes/config.yml ]; then
  # 仅首次生成（证书路径：/etc/tls/cert.pem /etc/tls/key.pem）
  T_UUID="$(uuidgen)"
  T_PASS="$(head -c16 /dev/urandom | xxd -p)"
  H_PASS="$(head -c16 /dev/urandom | xxd -p)"
  cat >/etc/shoes/config.yml <<EOF
- address: "[::]:8443"
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
  rules:
    - allow-all-direct
EOF
  chown root:shoes /etc/shoes/config.yml
  chmod 640      /etc/shoes/config.yml
  echo "TUIC UUID: $T_UUID"
  echo "TUIC PASS: $T_PASS"
  echo "HY2  PASS: $H_PASS"
fi

# ========== systemd ==========
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
Environment=RUST_LOG=warn
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now shoes
else
  systemctl try-reload-or-restart shoes || systemctl restart shoes
fi

# ========== 摘要 ==========
echo "== shoes version: $(/usr/local/bin/shoes -V 2>/dev/null || echo unknown) =="
ss -Hnplu | egrep ":443 |:8443 " || true
'
