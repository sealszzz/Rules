#!/usr/bin/env bash
set -euo pipefail

: "${A_PORT:=4443}"         # TCP/TLS (AnyTLS)
: "${V_PORT:=8443}"         # TCP/Reality (VLESS)
: "${T_PORT:=4443}"         # UDP/QUIC (TUIC v5)
: "${H_PORT:=8443}"         # UDP/QUIC (Hysteria2)

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

: "${A_PASS:=}"             # optional override; empty -> generate on first config
: "${V_UUID:=}"             # optional override; empty -> generate on first config
: "${T_UUID:=}"             # optional override; empty -> generate on first config
: "${T_PASS:=}"             # optional override; empty -> generate on first config
: "${H_PASS:=}"             # optional override; empty -> generate on first config

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
apt-get install -y --no-install-recommends \
  curl ca-certificates tar xz-utils uuid-runtime openssl iproute2

[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

getent group "$SHOES_GROUP" >/dev/null || groupadd --system "$SHOES_GROUP"
id -u "$SHOES_USER" >/dev/null 2>&1 || \
  useradd --system -g "$SHOES_GROUP" -M -d "$SHOES_STATE_DIR" -s /usr/sbin/nologin "$SHOES_USER"

install -d -o "$SHOES_USER" -g "$SHOES_GROUP" -m 750 "$SHOES_STATE_DIR"
install -d -o root -g "$SHOES_GROUP" -m 750 "$SHOES_CONF_DIR"

get_shoes_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
      https://github.com/cfal/shoes/releases/latest)" || return 1
  printf '%s\n' "${u##*/}"
}

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

  install -m 0755 "$bin" "$SHOES_BIN"
  trap - RETURN
}

SHOES_TAG="$(get_shoes_tag 2>/dev/null || true)"
install_shoes_release

gen_reality() {
  local out pri pub sid

  command -v "$SHOES_BIN" >/dev/null 2>&1 || {
    echo "FATAL: ${SHOES_BIN} not found" >&2
    exit 1
  }

  out="$("$SHOES_BIN" generate-reality-keypair 2>/dev/null || true)"

  pri="$(printf '%s\n' "$out" | awk -F': ' '/REALITY private key:/ {print $2; exit}')"
  pub="$(printf '%s\n' "$out" | awk -F': ' '/REALITY public key:/  {print $2; exit}')"

  if [ -z "${pri:-}" ] || [ -z "${pub:-}" ]; then
    echo "FATAL: failed to parse shoes generate-reality-keypair output" >&2
    echo "$out" >&2
    exit 1
  fi

  sid="$(openssl rand -hex 8)"  # 16 hex chars
  printf '%s\n' "$pri"
  printf '%s\n' "$pub"
  printf '%s\n' "$sid"
}

if [ ! -f "$SHOES_CONF_FILE" ]; then
  # unified: all secrets use the same one-liner
  [ -n "$A_PASS" ] || A_PASS="$(openssl rand -hex 16)"
  [ -n "$V_UUID" ] || V_UUID="$(uuidgen)"
  [ -n "$T_UUID" ] || T_UUID="$(uuidgen)"
  [ -n "$T_PASS" ] || T_PASS="$(openssl rand -hex 16)"
  [ -n "$H_PASS" ] || H_PASS="$(openssl rand -hex 16)"

  mapfile -t R < <(gen_reality)
  REALITY_PRI="${R[0]}"
  REALITY_PUB="${R[1]}"
  REALITY_SID="${R[2]}"

  cat >"$SHOES_CONF_FILE" <<EOF
- address: "[::]:${A_PORT}"
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

- address: "[::]:${V_PORT}"
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

- address: "[::]:${T_PORT}"
  transport: quic
  quic_settings:
    cert: "${CERT}"
    key:  "${KEY}"
    alpn_protocols:
      - h3
  protocol:
    type: tuic
    uuid: "${T_UUID}"
    password: "${T_PASS}"
    zero_rtt_handshake: false
    udp_enabled: true

- address: "[::]:${H_PORT}"
  transport: quic
  quic_settings:
    cert: "${CERT}"
    key:  "${KEY}"
    alpn_protocols:
      - h3
  protocol:
    type: hysteria2
    password: "${H_PASS}"
    udp_enabled: true
EOF

  chown root:"$SHOES_GROUP" "$SHOES_CONF_FILE"
  chmod 640 "$SHOES_CONF_FILE"
fi

# ===== systemd unit =====
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
if systemctl is-enabled "$SHOES_SERVICE_NAME" >/dev/null 2>&1; then
  systemctl restart "$SHOES_SERVICE_NAME"
else
  systemctl enable --now "$SHOES_SERVICE_NAME" >/dev/null 2>&1 || true
fi

BIN_VER="$("$SHOES_BIN" -V 2>/dev/null || "$SHOES_BIN" --version 2>/dev/null || true)"
echo "shoes tag: ${SHOES_TAG:-unknown}"
echo "shoes bin: ${BIN_VER:-unknown}"
