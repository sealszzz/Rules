#!/usr/bin/env bash
set -euo pipefail

: "${TT_LOG_LEVEL:=info}" # info debug trace
: "${TT_PORT:=8443}"
: "${TT_HOSTNAME:=www.example.com}"
: "${TT_ALLOWED_SNI:=www.example.com}"

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

TT_USER="trusttunnel"
TT_GROUP="trusttunnel"

TT_BIN="/usr/local/bin/trusttunnel"
TT_STATE_DIR="/var/lib/trusttunnel"
TT_CONF_DIR="/etc/trusttunnel"

TT_VPN="${TT_CONF_DIR}/vpn.toml"
TT_HOSTS="${TT_CONF_DIR}/hosts.toml"
TT_CREDS="${TT_CONF_DIR}/credentials.toml"

TT_SVC_NAME="trusttunnel"
TT_SVC="/etc/systemd/system/${TT_SVC_NAME}.service"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  curl ca-certificates tar xz-utils openssl

[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

getent group "$TT_GROUP" >/dev/null || groupadd --system "$TT_GROUP"
id -u "$TT_USER" >/dev/null 2>&1 || \
  useradd --system -g "$TT_GROUP" -M -d "$TT_STATE_DIR" -s /usr/sbin/nologin "$TT_USER"

install -d -o "$TT_USER" -g "$TT_GROUP" -m 750 "$TT_STATE_DIR"
install -d -o root -g "$TT_GROUP" -m 750 "$TT_CONF_DIR"

get_tt_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
      https://github.com/TrustTunnel/TrustTunnel/releases/latest)" || return 1
  printf '%s\n' "${u##*/}"
}

pick_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) echo "unsupported arch: $(uname -m)"; exit 1 ;;
  esac
}

install_tt_release_minimal() {
  local tag arch asset base tmpd unpackd ep

  tag="$(get_tt_tag)"
  [ -n "$tag" ] || { echo "FATAL: cannot resolve latest tag"; exit 1; }

  arch="$(pick_arch)"
  asset="trusttunnel-${tag}-linux-${arch}.tar.gz"
  base="https://github.com/TrustTunnel/TrustTunnel/releases/download/${tag}"

  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' RETURN

  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.tgz" "${base}/${asset}"
  unpackd="$tmpd/unpack"
  mkdir -p "$unpackd"
  tar -xzf "$tmpd/pkg.tgz" -C "$unpackd"

  ep="$(find "$unpackd" -type f -name trusttunnel_endpoint -perm -u+x | head -n1 || true)"
  [ -n "$ep" ] || { echo "FATAL: trusttunnel_endpoint not found in archive"; exit 1; }

  install -m 0755 "$ep" "$TT_BIN"

  trap - RETURN
  printf '%s\n' "$tag"
}

gen_user_pass() {
  local u p
  u="tt_$(openssl rand -hex 4)"
  p="$(openssl rand -hex 16)"
  printf '%s\n' "$u"
  printf '%s\n' "$p"
}

TAG="$(install_tt_release_minimal)"

# credentials.toml
if [ ! -f "$TT_CREDS" ]; then
  mapfile -t UP < <(gen_user_pass)
  TT_USERNAME="${UP[0]}"
  TT_PASSWORD="${UP[1]}"

  cat >"$TT_CREDS" <<EOF
[[client]]
username = "${TT_USERNAME}"
password = "${TT_PASSWORD}"
EOF

  chown root:"$TT_GROUP" "$TT_CREDS"
  chmod 640 "$TT_CREDS"

  echo "Generated credentials (${TT_CREDS}):"
  echo "  username: ${TT_USERNAME}"
  echo "  password: ${TT_PASSWORD}"
fi

# vpn.toml
if [ ! -f "$TT_VPN" ]; then
  cat >"$TT_VPN" <<EOF
listen_address = "[::]:${TT_PORT}"
ipv6_available = false
allow_private_network_connections = false
speedtest_enable = false

credentials_file = "${TT_CREDS}"

[listen_protocols]
[listen_protocols.http1]
[listen_protocols.http2]
[listen_protocols.quic]

[forward_protocol]
direct = {}

[reverse_proxy]
server_address = "127.0.0.1:9999"
path_mask = "/"
h3_backward_compatibility = false
EOF

  chown root:"$TT_GROUP" "$TT_VPN"
  chmod 640 "$TT_VPN"
fi

# hosts.toml
if [ ! -f "$TT_HOSTS" ]; then
  cat >"$TT_HOSTS" <<EOF
[[main_hosts]]
hostname = "${TT_HOSTNAME}"
cert_chain_path = "${CERT}"
private_key_path = "${KEY}"
allowed_sni = ["${TT_ALLOWED_SNI}"]

[[reverse_proxy_hosts]]
hostname = "localhost"
cert_chain_path = "${CERT}"
private_key_path = "${KEY}"
EOF

  chown root:"$TT_GROUP" "$TT_HOSTS"
  chmod 640 "$TT_HOSTS"
fi

if [ ! -f "$TT_SVC" ]; then
  cat >"$TT_SVC" <<EOF
[Unit]
Description=TrustTunnel endpoint
Documentation=https://github.com/TrustTunnel/TrustTunnel
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${TT_USER}
Group=${TT_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${TT_STATE_DIR}
ExecStart=${TT_BIN} ${TT_VPN} ${TT_HOSTS} -l ${TT_LOG_LEVEL}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$TT_SVC"
fi

systemctl daemon-reload
if systemctl is-enabled "$TT_SVC_NAME" >/dev/null 2>&1; then
  systemctl restart "$TT_SVC_NAME"
else
  systemctl enable --now "$TT_SVC_NAME" >/dev/null 2>&1 || true
fi

VER="$("$TT_BIN" --version 2>/dev/null || "$TT_BIN" -V 2>/dev/null || true)"
echo "trusttunnel tag: ${TAG:-unknown}"
echo "trusttunnel bin: ${VER:-unknown}"
