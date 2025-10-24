bash -c '
set -euo pipefail

# 0) 依赖 & 证书
apt update
apt install -y curl jq ca-certificates uuid-runtime openssl tar xz-utils unzip
[ -f /etc/tls/cert.pem ] || { echo "MISSING /etc/tls/cert.pem"; exit 1; }
[ -f /etc/tls/key.pem ]  || { echo "MISSING /etc/tls/key.pem";  exit 1; }

# 1) 用户/目录
getent group shoes >/dev/null || groupadd --system shoes
id -u shoes >/dev/null 2>&1 || useradd --system -g shoes -M -d /var/lib/shoes -s /usr/sbin/nologin shoes
install -d -o shoes -g shoes -m 750 /var/lib/shoes
install -d -o root  -g shoes -m 750 /etc/

# 2) 获取 GitHub 最新发布
json="$(curl -fsSL https://api.github.com/repos/cfal/shoes/releases/latest)"
latest_tag="$(echo "$json" | jq -r ".tag_name")"
assets="$(echo "$json" | jq -r ".assets[].name")"

# 读取本地已装版本
installed_tag=""
if command -v /usr/local/bin/shoes >/dev/null 2>&1; then
  vout="$(/usr/local/bin/shoes -V 2>/dev/null || true)"
  installed_tag="$(echo "$vout" | sed -nE "s/.*(v?[0-9]+(\.[0-9]+){1,3}).*/\1/p" | head -n1)"
fi
norm(){ printf "%s" "$1" | sed "s/^v//"; }

# 3) 如需则下载并安装二进制（优先 gnu，其次 musl）
need_install=1
if [ -n "$installed_tag" ] && [ "$(norm "$installed_tag")" = "$(norm "$latest_tag")" ]; then
  need_install=0
  echo "shoes is up-to-date ($installed_tag)"
fi

if [ "$need_install" -eq 1 ]; then
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) pat_arch="(x86_64|amd64)";;
    aarch64|arm64) pat_arch="(aarch64|arm64)";;
    *) echo "unsupported arch: $arch" >&2; exit 1;;
  esac
  pick(){ echo "$assets" | grep -i -E "$1" | head -n1 || true; }
  asset="$(pick "${pat_arch}.*(linux|unknown-linux).*gnu.*(\.tar\.gz|\.zip)$")"
  [ -n "$asset" ] || asset="$(pick "${pat_arch}.*(linux|unknown-linux).*musl.*(\.tar\.gz|\.zip)$")"
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
  [ -n "$binpath" ] || { echo "shoes binary not found in archive"; exit 1; }
  # 安装到 /usr/local/bin/shoes（备份旧的）
  if [ -x /usr/local/bin/shoes ]; then
    cp -a /usr/local/bin/shoes "/usr/local/bin/shoes.bak.$(date +%Y%m%d%H%M%S)" || true
  fi
  install -m 0755 "$binpath" /usr/local/bin/shoes
fi

# 4) 首次安装时生成最小配置（以后不动）
if [ ! -f /etc/shoes/config.yml ]; then
  T_UUID="$(uuidgen)"
  T_PASS="$(openssl rand -hex 16)"
  H_PASS="$(openssl rand -hex 16)"
  cat >/etc/shoes/config.yml <<EOF
- address: "[::]:443"
  transport: quic
  quic_settings:
    cert: "/etc/tls/cert.pem"
    key:  "/etc/tls/key.pem"
    alpn_protocols: ["h3","h3-29","h3-32","h3-34"]
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
    alpn_protocols: ["h3","h3-29","h3-32","h3-34"]
    congestion_control: bbr
  protocol:
    type: hysteria2
    password: "$H_PASS"
  rules:
    - allow-all-direct
EOF
  chown root:shoes /etc/shoes/config.yml
  chmod 640      /etc/shoes/config.yml
fi

# 5) systemd（首次创建，后续只重载重启）
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

# 6) 摘要
echo "== shoes version: $(/usr/local/bin/shoes -V 2>/dev/null || echo unknown) =="
ss -Hnplu | egrep ":443 |:8443 " || true
'
