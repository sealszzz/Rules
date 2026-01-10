#!/usr/bin/env bash
set -euo pipefail

: "${ANYTLS_PORT:=4443}"    # TCP/TLS
: "${TUIC_PORT:=4443}"      # UDP/QUIC
: "${VLESS_PORT:=8443}"     # TCP/Reality

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

: "${A_PASS:=}"   # optional override; empty -> generate on first config
: "${T_UUID:=}"   # optional override; empty -> generate on first config
: "${T_PASS:=}"   # optional override; empty -> generate on first config
: "${V_UUID:=}"   # optional override; empty -> generate on first config

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  curl ca-certificates tar xz-utils uuid-runtime openssl iproute2 \
  python3 python3-cryptography

[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

getent group shoes >/dev/null || groupadd --system shoes
id -u shoes >/dev/null 2>&1 || \
  useradd --system -g shoes -M -d /var/lib/shoes -s /usr/sbin/nologin shoes

install -d -o shoes -g shoes -m 750 /var/lib/shoes
install -d -o root  -g shoes -m 750 /etc/shoes

# ===== resolve latest tag via 302 =====
get_shoes_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
      https://github.com/cfal/shoes/releases/latest)" || return 1
  printf '%s\n' "${u##*/}"
}

# ===== install shoes =====
install_shoes_release() {
  case "$(uname -m)" in
    x86_64|amd64)  ASSET="shoes-x86_64-unknown-linux-gnu.tar.gz"  ;;
    aarch64|arm64) ASSET="shoes-aarch64-unknown-linux-gnu.tar.gz" ;;
    *) echo "unsupported arch: $(uname -m)"; exit 1 ;;
  esac

  local BASE="https://github.com/cfal/shoes/releases/latest/download"
  local tmpd
  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' RETURN

  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.tgz" "${BASE}/${ASSET}"
  mkdir -p "$tmpd/unpack"
  tar -xzf "$tmpd/pkg.tgz" -C "$tmpd/unpack"

  local bin
  bin="$(find "$tmpd/unpack" -type f -name shoes -perm -u+x | head -n1 || true)"
  [ -n "$bin" ] || { echo "FATAL: shoes binary not found"; exit 1; }

  install -m 0755 "$bin" /usr/local/bin/shoes
  trap - RETURN
}

SHOES_TAG="$(get_shoes_tag 2>/dev/null || true)"
install_shoes_release

# ===== generate Reality X25519 keypair (base64) + short_id (hex) WITHOUT xray =====
gen_reality() {
python3 - <<'PY'
import base64, os
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives import serialization

pri = x25519.X25519PrivateKey.generate()
pub = pri.public_key()

pri_raw = pri.private_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PrivateFormat.Raw,
    encryption_algorithm=serialization.NoEncryption()
)
pub_raw = pub.public_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PublicFormat.Raw
)

print(base64.b64encode(pri_raw).decode())
print(base64.b64encode(pub_raw).decode())
print(os.urandom(8).hex())  # 16 hex chars
PY
}

# ===== config: create only if missing =====
if [ ! -f /etc/shoes/config.yaml ]; then
  [ -n "$A_PASS" ] || A_PASS="$(openssl rand -hex 16)"
  [ -n "$T_UUID" ] || T_UUID="$(uuidgen)"
  [ -n "$T_PASS" ] || T_PASS="$(openssl rand -hex 16)"
  [ -n "$V_UUID" ] || V_UUID="$(uuidgen)"

  mapfile -t R < <(gen_reality)
  REALITY_PRI="${R[0]}"
  REALITY_PUB="${R[1]}"
  REALITY_SID="${R[2]}"

  cat >/etc/shoes/config.yaml <<EOF
- address: "[::]:${ANYTLS_PORT}"
  protocol:
    type: tls
    tls_targets:
      "www.cloudflare.com":
        cert: "${CERT}"
        key:  "${KEY}"
        protocol:
          type: anytls
          users:
            - name: user1
              password: "${A_PASS}"
          udp_enabled: true
          fallback: "127.0.0.1:80"

- address: "[::]:${VLESS_PORT}"
  protocol:
    type: tls
    reality_targets:
      "www.cloudflare.com":
        private_key: "${REALITY_PRI}"
        #public_key: "${REALITY_PUB}"
        short_ids: ["${REALITY_SID}"]
        dest: "localhost:9999"
        vision: true
        protocol:
          type: vless
          user_id: "${V_UUID}"
          udp_enabled: true
          fallback: "127.0.0.1:80"

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
    zero_rtt_handshake: false
    udp_enabled: true

  rules:
    - allow-all-direct
EOF

  chown root:shoes /etc/shoes/config.yaml
  chmod 640 /etc/shoes/config.yaml
fi

# ===== systemd unit =====
if [ ! -f /etc/systemd/system/shoes.service ]; then
  cat >/etc/systemd/system/shoes.service <<'EOF'
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
ExecStart=/usr/local/bin/shoes /etc/shoes/config.yaml
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 /etc/systemd/system/shoes.service
fi

systemctl daemon-reload
if systemctl is-enabled shoes >/dev/null 2>&1; then
  systemctl restart shoes
else
  systemctl enable --now shoes >/dev/null 2>&1 || true
fi

# ===== final output (ONLY tag + bin) =====
BIN_VER="$(/usr/local/bin/shoes -V 2>/dev/null || /usr/local/bin/shoes --version 2>/dev/null || true)"
echo "shoes tag: ${SHOES_TAG:-unknown}"
echo "shoes bin: ${BIN_VER:-unknown}"
