#!/usr/bin/env bash
set -euo pipefail

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"
: "${PASS:=}"
: "${UUID:=}"
: "${SS_PASS:=}"

SHOES_USER="shoes"
SHOES_GROUP="shoes"
SHOES_STATE_DIR="/var/lib/shoes"
SHOES_CONF_DIR="/etc/shoes"
SHOES_CONF_FILE="${SHOES_CONF_DIR}/config.yaml"
SHOES_BIN="/usr/local/bin/shoes"
SHOES_SERVICE_NAME="shoes"
SHOES_SERVICE="/etc/systemd/system/${SHOES_SERVICE_NAME}.service"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates tar xz-utils uuid-runtime openssl iproute2

[ -r "$CERT" ] || { echo "FATAL: missing $CERT" >&2; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY"  >&2; exit 1; }

getent group "$SHOES_GROUP" >/dev/null || groupadd --system "$SHOES_GROUP"
id -u "$SHOES_USER" >/dev/null 2>&1 || useradd --system -g "$SHOES_GROUP" -M -d "$SHOES_STATE_DIR" -s /usr/sbin/nologin "$SHOES_USER"

install -d -o "$SHOES_USER" -g "$SHOES_GROUP" -m 750 "$SHOES_STATE_DIR"
install -d -o root -g "$SHOES_GROUP" -m 750 "$SHOES_CONF_DIR"

get_shoes_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/cfal/shoes/releases/latest)" || return 1
  printf '%s\n' "${u##*/}"
}

install_shoes_release() {
  local ASSET BASE tmpd bin
  case "$(uname -m)" in
    x86_64|amd64)  ASSET="shoes-x86_64-unknown-linux-gnu.tar.gz"  ;;
    aarch64|arm64) ASSET="shoes-aarch64-unknown-linux-gnu.tar.gz" ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac

  BASE="https://github.com/cfal/shoes/releases/latest/download"
  tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' RETURN

  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.tgz" "${BASE}/${ASSET}"
  mkdir -p "$tmpd/unpack"
  tar -xzf "$tmpd/pkg.tgz" -C "$tmpd/unpack"

  bin="$(find "$tmpd/unpack" -type f -name shoes -perm -u+x | head -n1 || true)"
  [ -n "$bin" ] || { echo "FATAL: shoes binary not found" >&2; exit 1; }

  install -m 0755 "$bin" "$SHOES_BIN"
  trap - RETURN
}

SHOES_TAG="$(get_shoes_tag 2>/dev/null || true)"
install_shoes_release

command -v "$SHOES_BIN" >/dev/null 2>&1 || { echo "FATAL: ${SHOES_BIN} not found" >&2; exit 1; }

gen_reality() {
  local out pri pub sid
  out="$("$SHOES_BIN" generate-reality-keypair 2>/dev/null || true)"
  pri="$(awk -F': ' '/REALITY private key:/ {print $2; exit}' <<<"$out")"
  pub="$(awk -F': ' '/REALITY public key:/  {print $2; exit}' <<<"$out")"
  [ -n "${pri:-}" ] && [ -n "${pub:-}" ] || { echo "FATAL: reality keypair parse failed" >&2; echo "$out" >&2; exit 1; }
  sid="$(openssl rand -hex 8)"
  printf '%s\n%s\n%s\n' "$pri" "$pub" "$sid"
}

gen_ss2022_pass() {
  local pw
  pw="$("$SHOES_BIN" generate-shadowsocks-2022-password 2022-blake3-aes-128-gcm 2>/dev/null \
    | awk -F': ' '/^Password:/ {print $2; exit}')"
  [ -n "${pw:-}" ] || { echo "FATAL: SS2022 password gen failed" >&2; exit 1; }
  printf '%s\n' "$pw"
}

if [ ! -f "$SHOES_CONF_FILE" ]; then
  [ -n "$PASS" ] || PASS="$(openssl rand -hex 16)"
  [ -n "$UUID" ] || UUID="$(uuidgen)"
  [ -n "$SS_PASS" ] || SS_PASS="$(gen_ss2022_pass)"

  mapfile -t R < <(gen_reality)
  REALITY_PRI="${R[0]}"; REALITY_PUB="${R[1]}"; REALITY_SID="${R[2]}"

  cat >"$SHOES_CONF_FILE" <<EOF
- address: "[::]:4443"
  protocol:
    type: tls
    tls_targets:
      "www.cloudflare.com":
        cert: "${CERT}"
        key: "${KEY}"
        protocol:
          type: anytls
          users:
            - name: anytls
              password: "${PASS}"
          udp_enabled: true
          padding_scheme:
            - "stop=9"
            - "1=30-30"
            - "2=100-400"
            - "3=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000"
            - "4=9-9,500-1000"
            - "5=500-1000"
            - "6=500-1000"
            - "7=500-1000"
            - "8=500-1000"
          fallback: "127.0.0.1:80"

- address: "[::]:5443"
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
          user_id: "${UUID}"
          udp_enabled: true
        fallback: "127.0.0.1:9999"

- address: "[::]:6443"
  protocol:
    type: tls
    reality_targets:
      "www.cloudflare.com":
        private_key: "${REALITY_PRI}"
        #public_key: "${REALITY_PUB}"
        short_ids: ["${REALITY_SID}"]
        dest: "localhost:9999"
        protocol:
          type: naiveproxy
          users:
            - username: naive
              password: "${PASS}"
          udp_enabled: true
        fallback: "127.0.0.1:9999"

- address: "[::]:7443"
  protocol:
    type: tls
    tls_targets:
      "www.cloudflare.com":
        cert: "${CERT}"
        key: "${KEY}"
        alpn_protocols: ["h2", "http/1.1"]
        protocol:
          type: naiveproxy
          users:
            - name: naive
              password: "${PASS}"
          padding: true
          udp_enabled: true
          fallback: "/var/www/html"

- address: "[::]:8443"
  protocol:
    type: shadowsocks
    cipher: 2022-blake3-aes-128-gcm
    password: "${SS_PASS}"
    udp_enabled: true

- address: "[::]:4443"
  transport: quic
  quic_settings:
    cert: "${CERT}"
    key: "${KEY}"
    alpn_protocols: [h3]
  protocol:
    type: tuic
    uuid: "${UUID}"
    password: "${PASS}"
    zero_rtt_handshake: false
    udp_enabled: true

- address: "[::]:5443"
  transport: quic
  quic_settings:
    cert: "${CERT}"
    key: "${KEY}"
    alpn_protocols: [h3]
  protocol:
    type: hysteria2
    password: "${PASS}"
    udp_enabled: true
EOF

  chown root:"$SHOES_GROUP" "$SHOES_CONF_FILE"
  chmod 640 "$SHOES_CONF_FILE"
fi

if [ ! -f "$SHOES_SERVICE" ]; then
  cat >"$SHOES_SERVICE" <<EOF
[Unit]
Description=Shoes Server
Documentation=https://github.com/cfal/shoes
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${SHOES_USER}
Group=${SHOES_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${SHOES_STATE_DIR}
ExecStart=${SHOES_BIN} ${SHOES_CONF_FILE}
Environment="RUST_LOG=info"
# Environment="RUST_LOG=warn,shoes=debug,quinn=error"
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SHOES_SERVICE"
fi

systemctl daemon-reload
if systemctl is-enabled --quiet "$SHOES_SERVICE_NAME"; then
  systemctl restart "$SHOES_SERVICE_NAME"
else
  systemctl enable --now "$SHOES_SERVICE_NAME"
fi

BIN_VER="$("$SHOES_BIN" -V 2>/dev/null || "$SHOES_BIN" --version 2>/dev/null || true)"
echo "shoes tag: ${SHOES_TAG:-unknown}"
echo "shoes bin: ${BIN_VER:-unknown}"
