#!/usr/bin/env bash
set -euo pipefail

: "${APP_USER:=caddy-l4}"
: "${APP_GROUP:=caddy-l4}"
: "${APP_BIN:=/usr/local/bin/caddy-l4}"
: "${APP_CONF_DIR:=/etc/caddy-l4}"
: "${APP_CONF:=/etc/caddy-l4/config.json}"
: "${APP_SERVICE_NAME:=caddy-l4}"
: "${APP_SERVICE:=/etc/systemd/system/${APP_SERVICE_NAME}.service}"
: "${APP_REPO:=sealszzz/caddy}"
: "${APP_TAG:=}"

export DEBIAN_FRONTEND=noninteractive

[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root"; exit 1; }

apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates tar >/dev/null

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
  amd64|x86_64) ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "FATAL: unsupported arch"; exit 1 ;;
esac

get_latest_tag() {
  local u
  u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${APP_REPO}/releases/latest")" || return 1
  printf '%s\n' "${u##*/}"
}

[ -n "${APP_TAG}" ] || APP_TAG="$(get_latest_tag)"
[ -n "${APP_TAG}" ] || { echo "FATAL: failed to get latest tag"; exit 1; }

ASSET="caddy-l4-linux-${ARCH}-${APP_TAG}.tar.gz"
URL="https://github.com/${APP_REPO}/releases/download/${APP_TAG}/${ASSET}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 3 --retry-delay 1 -o "$TMP/$ASSET" "$URL"
tar -xzf "$TMP/$ASSET" -C "$TMP"

[ -f "$TMP/caddy-l4" ] || { echo "FATAL: missing caddy-l4 binary in tar"; exit 1; }
install -m 0755 "$TMP/caddy-l4" "$APP_BIN"

getent group "$APP_GROUP" >/dev/null || groupadd --system "$APP_GROUP"
id -u "$APP_USER" >/dev/null 2>&1 || useradd \
  --system \
  --no-create-home \
  --gid "$APP_GROUP" \
  --shell /usr/sbin/nologin \
  "$APP_USER"

install -d -o root -g "$APP_GROUP" -m 0750 "$APP_CONF_DIR"

if [ ! -f "$APP_CONF" ]; then
cat >"$APP_CONF" <<'EOF'
{
  "admin": { "disabled": true },
  "logging": {
    "logs": {
      "default": {
        "level": "WARN",
        "writer": { "output": "stderr" },
        "encoder": { "format": "console" }
      }
    }
  },
  "apps": {
    "layer4": {
      "servers": {
        "tcp443": {
          "listen": [":443"],
          "matching_timeout": "1s",
          "routes": [
            {
              "match": [{ "tls": {} }],
              "handle": [{
                "handler": "subroute",
                "routes": [
                  {
                    "match": [{ "tls": { "sni": ["example.com"] } }],
                    "handle": [{
                      "handler": "proxy",
                      "proxy_protocol": "v2",
                      "upstreams": [{ "dial": ["tcp/[::1]:9001"] }]
                    }]
                  },
                  {
                    "match": [{ "tls": { "sni": ["www.example.com"] } }],
                    "handle": [{
                      "handler": "proxy",
                      "proxy_protocol": "v2",
                      "upstreams": [{ "dial": ["tcp/[::1]:9002"] }]
                    }]
                  },
                  {
                    "match": [{ "tls": { "sni": ["*.example.com"] } }],
                    "handle": [{
                      "handler": "proxy",
                      "proxy_protocol": "v2",
                      "upstreams": [{ "dial": ["tcp/[::1]:9999"] }]
                    }]
                  },
                  {
                    "handle": [{ "handler": "close" }]
                  }
                ]
              }]
            },
            {
              "match": [{ "not": [{ "tls": {} }] }],
              "handle": [{
                "handler": "proxy",
                "upstreams": [{ "dial": ["tcp/[::1]:9009"] }]
              }]
            }
          ]
        },
        "udp443": {
          "listen": ["udp/:443"],
          "matching_timeout": "1s",
          "routes": [
            {
              "match": [{ "quic": {} }],
              "handle": [{
                "handler": "subroute",
                "routes": [
                  {
                    "match": [{ "quic": { "sni": ["example.com"] } }],
                    "handle": [{
                      "handler": "proxy",
                      "upstreams": [{ "dial": ["udp/[::1]:9001"] }]
                    }]
                  },
                  {
                    "match": [{ "quic": { "sni": ["www.example.com"] } }],
                    "handle": [{
                      "handler": "proxy",
                      "upstreams": [{ "dial": ["udp/[::1]:9002"] }]
                    }]
                  },
                  {
                    "match": [{ "quic": { "sni": ["*.example.com"] } }],
                    "handle": [{
                      "handler": "proxy",
                      "upstreams": [{ "dial": ["udp/[::1]:9999"] }]
                    }]
                  },
                  {
                    "handle": [{
                      "handler": "throttle",
                      "read_bytes_per_second": 8,
                      "read_burst_size": 8
                    }]
                  }
                ]
              }]
            },
            {
              "match": [{ "not": [{ "quic": {} }] }],
              "handle": [{
                "handler": "proxy",
                "upstreams": [{ "dial": ["udp/[::1]:9009"] }]
              }]
            }
          ]
        }
      }
    }
  }
}
EOF
fi

chown root:"$APP_GROUP" "$APP_CONF"
chmod 0640 "$APP_CONF"

"$APP_BIN" validate --config "$APP_CONF"

cat >"$APP_SERVICE" <<EOF
[Unit]
Description=caddy-l4
After=network-online.target
Wants=network-online.target

[Service]
User=${APP_USER}
Group=${APP_GROUP}
Type=simple
WorkingDirectory=/var/lib/${APP_SERVICE_NAME}
StateDirectory=${APP_SERVICE_NAME}
Environment=HOME=/var/lib/${APP_SERVICE_NAME}
ExecStart=${APP_BIN} run --config ${APP_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$APP_SERVICE"

systemctl daemon-reload
if systemctl is-enabled --quiet "$APP_SERVICE_NAME"; then
  systemctl restart "$APP_SERVICE_NAME"
else
  systemctl enable --now "$APP_SERVICE_NAME"
fi

echo "caddy-l4 installed: ${APP_TAG}"
echo "binary: ${APP_BIN}"
echo "config: ${APP_CONF}"
echo "service: ${APP_SERVICE_NAME}"
echo
echo "=== caddy-l4 version ==="
"$APP_BIN" version 2>/dev/null || "$APP_BIN" --version 2>/dev/null || true
