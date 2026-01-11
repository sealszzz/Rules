#!/usr/bin/env bash
set -euo pipefail

: "${ANYTLS_PORT:=4443}"    # TCP/TLS

: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

: "${A_PASS:=}"             # optional override; empty -> generate on first install

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  curl ca-certificates tar openssl

[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

getent group anytls >/dev/null || groupadd --system anytls
id -u anytls >/dev/null 2>&1 || \
  useradd --system -g anytls -M -d /var/lib/anytls -s /usr/sbin/nologin anytls

install -d -o anytls -g anytls -m 750 /var/lib/anytls

# ===== resolve latest tag via 302 =====
get_anytls_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
      https://github.com/ssrlive/anytls-rs/releases/latest)" || return 1
  printf '%s\n' "${u##*/}"
}

# ===== install anytls-rs =====
install_anytls_release() {
  case "$(uname -m)" in
    x86_64|amd64)  ASSET="anytls_linux_x86_64.tar.gz"  ;;
    aarch64|arm64) ASSET="anytls_linux_aarch64.tar.gz" ;;
    *) echo "unsupported arch: $(uname -m)"; exit 1 ;;
  esac

  local BASE="https://github.com/ssrlive/anytls-rs/releases/latest/download"
  local tmpd
  tmpd="$(mktemp -d)"
  trap 'rm -rf "$tmpd"' RETURN

  curl -fL --retry 3 --retry-delay 1 -o "$tmpd/pkg.tgz" "${BASE}/${ASSET}"
  mkdir -p "$tmpd/unpack"
  tar -xzf "$tmpd/pkg.tgz" -C "$tmpd/unpack"

  local bin
  bin="$(find "$tmpd/unpack" -type f -name anytls -perm -u+x | head -n1 || true)"
  [ -n "$bin" ] || { echo "FATAL: anytls binary not found"; exit 1; }

  install -m 0755 "$bin" /usr/local/bin/anytls
  trap - RETURN
}

ANYTLS_TAG="$(get_anytls_tag 2>/dev/null || true)"
install_anytls_release

# ===== systemd unit (create only if missing) =====
FIRST_INSTALL=0
if [ ! -f /etc/systemd/system/anytls.service ]; then
  FIRST_INSTALL=1
  [ -n "$A_PASS" ] || A_PASS="$(openssl rand -hex 16)"

  cat >/etc/systemd/system/anytls.service <<EOF
[Unit]
Description=AnyTLS Server (anytls-rs)
Documentation=https://github.com/ssrlive/anytls-rs
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=anytls
Group=anytls
Type=simple
UMask=0077
WorkingDirectory=/var/lib/anytls
ExecStart=/usr/local/bin/anytls -l [::]:${ANYTLS_PORT} -p ${A_PASS} --cert ${CERT} --key ${KEY}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 /etc/systemd/system/anytls.service
fi

systemctl daemon-reload
if systemctl is-enabled anytls >/dev/null 2>&1; then
  systemctl restart anytls
else
  systemctl enable --now anytls >/dev/null 2>&1 || true
fi

# ===== final output (tag + bin + password) =====
BIN_VER="$(/usr/local/bin/anytls -V 2>/dev/null || /usr/local/bin/anytls --version 2>/dev/null || true)"
echo "anytls tag: ${ANYTLS_TAG:-unknown}"
echo "anytls bin: ${BIN_VER:-unknown}"
if [ "$FIRST_INSTALL" -eq 1 ]; then
  echo "anytls password: ${A_PASS}"
else
  echo "anytls password: (unchanged; stored in /etc/systemd/system/anytls.service)"
fi
