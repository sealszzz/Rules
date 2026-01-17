#!/usr/bin/env bash
set -euo pipefail

: "${J_PORT:=4443}"
: "${CERT:=/etc/tls/cert.pem}"
: "${KEY:=/etc/tls/key.pem}"

J_USER="juicity"
J_GROUP="juicity"

J_STATE_DIR="/var/lib/juicity"
J_ETC_DIR="/etc/juicity"
J_CONF="${J_ETC_DIR}/server.json"

J_BIN="/usr/local/bin/juicity"
J_SVC_NAME="juicity"
J_SVC="/etc/systemd/system/${J_SVC_NAME}.service"

export DEBIAN_FRONTEND=noninteractive

apt-get update >/dev/null
apt-get install -y --no-install-recommends \
  curl ca-certificates unzip openssl uuid-runtime iproute2 >/dev/null

[ -r "$CERT" ] || { echo "FATAL: missing $CERT"; exit 1; }
[ -r "$KEY"  ] || { echo "FATAL: missing $KEY";  exit 1; }

detect_egress_ipv4() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  fi
  if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "${ip}"
    return 0
  fi
  return 1
}

detect_egress_ipv6() {
  local ip=""
  ip="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  fi
  if [[ -n "${ip}" && "${ip}" == *:* ]]; then
    printf '%s\n' "${ip}"
    return 0
  fi
  return 1
}

SEND_THROUGH_LINE=""
J_IPV4=""
J_IPV6=""

if J_IPV4="$(detect_egress_ipv4)"; then :; else J_IPV4=""; fi
if J_IPV6="$(detect_egress_ipv6)"; then :; else J_IPV6=""; fi

if [[ -n "${J_IPV4}" && -n "${J_IPV6}" ]]; then
  echo "Dual-stack detected (IPv4=${J_IPV4}, IPv6=${J_IPV6}); enabling send_through=${J_IPV4}"
  SEND_THROUGH_LINE="  \"send_through\": \"${J_IPV4}\","
else
  if [[ -n "${J_IPV4}" ]]; then
    echo "IPv4-only (or IPv6 not usable); omitting send_through."
  elif [[ -n "${J_IPV6}" ]]; then
    echo "IPv6-only (no usable IPv4); omitting send_through."
  else
    echo "WARN: could not detect usable IPv4/IPv6; omitting send_through."
  fi
fi

getent group "$J_GROUP" >/dev/null || groupadd --system "$J_GROUP"
id -u "$J_USER" >/dev/null 2>&1 || \
  useradd --system -g "$J_GROUP" -M -d "$J_STATE_DIR" -s /usr/sbin/nologin "$J_USER"

install -d -o "$J_USER" -g "$J_GROUP" -m 750 "$J_STATE_DIR"
install -d -o root      -g "$J_GROUP" -m 750 "$J_ETC_DIR"

get_latest_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
    https://github.com/juicity/juicity/releases/latest)" || return 1
  printf '%s\n' "${u##*/}"
}

TAG="$(get_latest_tag)" || { echo "Failed to resolve latest tag"; exit 1; }

case "$(uname -m)" in
  x86_64|amd64)
    ASSET="juicity-linux-x86_64_v3_avx2.zip"
    ;;
  aarch64|arm64)
    ASSET="juicity-linux-arm64.zip"
    ;;
  *)
    echo "Unsupported arch: $(uname -m)" >&2
    exit 1
    ;;
esac

URL="https://github.com/juicity/juicity/releases/download/${TAG}/${ASSET}"

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

curl -fL --retry 3 --retry-delay 1 -o "${tmpd}/${ASSET}" "$URL"
unzip -q "${tmpd}/${ASSET}" -d "$tmpd"

[ -f "${tmpd}/juicity-server" ] || { echo "FATAL: juicity-server not found"; exit 1; }

install -m 0755 "${tmpd}/juicity-server" "$J_BIN"

if [ ! -f "$J_CONF" ]; then
  J_UUID="$(uuidgen)"
  J_PASS="$(openssl rand -hex 16)"

  {
    printf '{\n'
    printf '  "listen": "[::]:%s",\n' "${J_PORT}"
    printf '  "users": {\n'
    printf '    "%s": "%s"\n' "${J_UUID}" "${J_PASS}"
    printf '  },\n'
    printf '  "certificate": "%s",\n' "${CERT}"
    printf '  "private_key": "%s",\n' "${KEY}"
    printf '  "congestion_control": "bbr",\n'
    printf '  "disable_outbound_udp443": true,\n'
    [[ -n "${SEND_THROUGH_LINE}" ]] && printf '%s\n' "${SEND_THROUGH_LINE}"
    printf '  "log_level": "warn"\n'
    printf '}\n'
  } >"$J_CONF"

  chown root:"$J_GROUP" "$J_CONF"
  chmod 640 "$J_CONF"

  echo "JUICITY UUID: ${J_UUID}"
  echo "JUICITY PASS: ${J_PASS}"
else
  echo "INFO: ${J_CONF} already exists; not modifying it."
  if [[ -n "${SEND_THROUGH_LINE}" ]]; then
    echo "      (dual-stack) If you want, add this line into JSON: ${SEND_THROUGH_LINE}"
  fi
fi

if [ ! -f "$J_SVC" ]; then
  cat >"$J_SVC" <<EOF
[Unit]
Description=Juicity Server
Documentation=https://github.com/juicity/juicity
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${J_USER}
Group=${J_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${J_STATE_DIR}
ExecStart=${J_BIN} run -c ${J_CONF} --disable-timestamp
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$J_SVC"
fi

systemctl daemon-reload
if systemctl is-enabled "$J_SVC_NAME" >/dev/null 2>&1; then
  systemctl try-reload-or-restart "$J_SVC_NAME" || systemctl restart "$J_SVC_NAME"
else
  systemctl enable --now "$J_SVC_NAME" || true
fi

"$J_BIN" --version 2>/dev/null || true
