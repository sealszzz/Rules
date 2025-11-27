#!/usr/bin/env bash
set -euo pipefail

: "${TUIC_PORT:=4443}"
: "${VLESS_PORT:=4443}"
: "${RUST_LOG:=warn}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

: "${REALITY_SNI:=www.google.com}"
: "${REALITY_DEST:=${REALITY_SNI}:443}"

: "${T_UUID:=$(uuidgen)}"
: "${T_PASS:=$(openssl rand -hex 16 || echo '0123456789abcdef0123456789abcdef')}"
: "${V_UUID:=$(uuidgen)}"

export DEBIAN_FRONTEND=noninteractive

gen_reality_keys() {
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 8 2>/dev/null || echo '0123456789abcdef')}"

  if [ -n "${REALITY_PRIVATE_KEY:-}" ] && [ -n "${REALITY_PUBLIC_KEY:-}" ]; then
    return 0
  fi

  local out
  out="$(python3 - <<'PY'
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives import serialization
import base64

priv = x25519.X25519PrivateKey.generate()
pub = priv.public_key()

priv_raw = priv.private_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PrivateFormat.Raw,
    encryption_algorithm=serialization.NoEncryption()
)
pub_raw = pub.public_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PublicFormat.Raw
)

def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b'=').decode()

print("PRIVATE=" + b64u(priv_raw))
print("PUBLIC=" + b64u(pub_raw))
PY
)" || { echo "生成 Reality 密钥对失败"; exit 1; }

  REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-$(printf '%s\n' "$out" | awk -F= '/^PRIVATE=/{print $2}')}"
  REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-$(printf '%s\n' "$out" | awk -F= '/^PUBLIC=/{print $2}')}"
}

apt update
apt install -y --no-install-recommends \
  curl jq ca-certificates tar unzip xz-utils uuid-runtime openssl iproute2 \
  python3 python3-cryptography

[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

gen_reality_keys

getent group shoes >/dev/null || groupadd --system shoes
id -u shoes  >/dev/null 2>&1 || useradd --system -g shoes -M -d /var/lib/shoes -s /usr/sbin/nologin shoes
install -d -o shoes -g shoes -m 750 /var/lib/shoes
install -d -o root  -g shoes -m 750 /etc/shoes

install_shoes_release() {
  case "$(uname -m)" in
    x86_64|amd64)  ASSET="shoes-x86_64-unknown-linux-gnu.tar.gz"  ;;
    aarch64|arm64) ASSET="shoes-aarch64-unknown-linux-gnu.tar.gz" ;;
    *) echo "unsupported arch: $(uname -m)"; exit 1 ;;
  esac

  local BASE="https://github.com/cfal/shoes/releases/latest/download"
  local tmpd; tmpd="$(mktemp -d)"
  trap 't="${tmpd-}"; [ -n "$t" ] && rm -rf -- "$t"' RETURN

  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.tgz" "${BASE}/${ASSET}"
  mkdir -p "$tmpd/unpack"
  tar -xzf "$tmpd/pkg.tgz" -C "$tmpd/unpack"

  local bin
  bin="$(find "$tmpd/unpack" -type f -name shoes -perm -u+x | head -n1 || true)"
  [ -n "$bin" ] || { echo "未在资产中找到 shoes 可执行文件"; exit 1; }

  install -m 0755 "$bin" /usr/local/bin/shoes
  trap - RETURN
}

install_shoes_release

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

- address: "[::]:${VLESS_PORT}"
  protocol:
    type: tls
    reality_targets:
      "${REALITY_SNI}":
        private_key: "${REALITY_PRIVATE_KEY}"
        public_key:  "${REALITY_PUBLIC_KEY}"
        short_ids: ["${REALITY_SHORT_ID}"]
        dest: "${REALITY_DEST}"
        vision: true
        protocol:
          type: vless
          user_id: "${V_UUID}"
          udp_enabled: true
  rules:
    - allow-all-direct
EOF
  chown root:shoes /etc/shoes/config.yml
  chmod 640      /etc/shoes/config.yml

fi

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

systemctl daemon-reload
systemctl enable --now shoes || true
systemctl try-reload-or-restart shoes || systemctl restart shoes

echo
ver="$(
  /usr/local/bin/shoes -V 2>/dev/null \
  || /usr/local/bin/shoes --version 2>/dev/null \
  || true
)"
echo "shoes version: ${ver:-unknown}"
echo

echo "监听检查（TUIC / UDP 端口 ${TUIC_PORT}）："
ss -Hnplu 2>/dev/null | grep -E ":${TUIC_PORT}([^0-9]|$)" || echo "未发现 UDP ${TUIC_PORT}"

echo
echo "监听检查（VLESS / TCP 端口 ${VLESS_PORT}）："
ss -Hnplt 2>/dev/null | grep -E ":${VLESS_PORT}([^0-9]|$)" || echo "未发现 TCP ${VLESS_PORT}"
