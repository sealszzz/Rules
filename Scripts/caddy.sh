#!/usr/bin/env bash
set -euo pipefail

: "${CADDY_USER:=caddy}"
: "${CADDY_GROUP:=caddy}"
: "${CADDY_BIN:=/usr/local/bin/caddy-l4}"
: "${CADDY_CONF:=/etc/caddy/caddy.json}"
: "${CADDY_SERVICE:=/etc/systemd/system/caddy-l4.service}"
: "${CADDY_REPO:=sealszzz/Caddy}"
: "${SERVICE_NAME:=caddy-l4}"

export DEBIAN_FRONTEND=noninteractive
[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root"; exit 1; }

apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates tar >/dev/null

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
  amd64|x86_64) ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "FATAL: unsupported arch"; exit 1 ;;
esac

LATEST_URL="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${CADDY_REPO}/releases/latest")"
TAG="${LATEST_URL##*/}"
[ -n "$TAG" ] || { echo "FATAL: failed to get tag"; exit 1; }

ASSET="caddy-l4-linux-${ARCH}-${TAG}.tar.gz"
URL="https://github.com/${CADDY_REPO}/releases/download/${TAG}/${ASSET}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 3 --retry-delay 1 -o "$TMP/$ASSET" "$URL"
tar -xzf "$TMP/$ASSET" -C "$TMP"

[ -f "$TMP/caddy-l4-linux-${ARCH}" ] || { echo "FATAL: missing binary in tar"; exit 1; }
install -m 0755 "$TMP/caddy-l4-linux-${ARCH}" "$CADDY_BIN"

getent group "$CADDY_GROUP" >/dev/null || groupadd --system "$CADDY_GROUP"
id -u "$CADDY_USER" >/dev/null 2>&1 || useradd --system --no-create-home --gid "$CADDY_GROUP" --shell /usr/sbin/nologin "$CADDY_USER"

install -d -o root -g "$CADDY_GROUP" -m 0750 /etc/caddy

# Write config once (only if not exists)
if [ ! -f "$CADDY_CONF" ]; then
cat >"$CADDY_CONF" <<'EOF'
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
          "matching_timeout": "500ms",
          "routes": [
            {
              "match": [
                { "tls": {} }
              ],
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "match": [
                        { "tls": { "sni": ["example.com"] } }
                      ],
                      "handle": [
                        {
                          "handler": "proxy",
                          "upstreams": [
                            { "dial": ["tcp/127.0.0.1:9001"] }
                          ]
                        }
                      ]
                    },
                    {
                      "match": [
                        { "tls": { "sni": ["www.example.com"] } }
                      ],
                      "handle": [
                        {
                          "handler": "proxy",
                          "upstreams": [
                            { "dial": ["tcp/127.0.0.1:9002"] }
                          ]
                        }
                      ]
                    },
                    {
                      "match": [
                        { "tls": { "sni": ["*.example.com"] } }
                      ],
                      "handle": [
                        {
                          "handler": "proxy",
                          "upstreams": [
                            { "dial": ["tcp/127.0.0.1:9999"] }
                          ]
                        }
                      ]
                    },
                    {
                      "handle": [
                        {
                          "handler": "throttle",
                          "read_bytes_per_second": 8,
                          "read_burst_size": 8
                        }
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "match": [
                { "not": [ { "tls": {} } ] }
              ],
              "handle": [
                {
                  "handler": "proxy",
                  "upstreams": [
                    { "dial": ["tcp/127.0.0.1:9009"] }
                  ]
                }
              ]
            }
          ]
        },

        "udp443": {
          "listen": ["udp/:443"],
          "matching_timeout": "500ms",
          "routes": [
            {
              "match": [
                { "quic": {} }
              ],
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "match": [
                        { "quic": { "sni": ["example.com"] } }
                      ],
                      "handle": [
                        {
                          "handler": "proxy",
                          "upstreams": [
                            { "dial": ["udp/127.0.0.1:9001"] }
                          ]
                        }
                      ]
                    },
                    {
                      "match": [
                        { "quic": { "sni": ["www.example.com"] } }
                      ],
                      "handle": [
                        {
                          "handler": "proxy",
                          "upstreams": [
                            { "dial": ["udp/127.0.0.1:9002"] }
                          ]
                        }
                      ]
                    },
                    {
                      "match": [
                        { "quic": { "sni": ["*.example.com"] } }
                      ],
                      "handle": [
                        {
                          "handler": "proxy",
                          "upstreams": [
                            { "dial": ["udp/127.0.0.1:9999"] }
                          ]
                        }
                      ]
                    },
                    {
                      "handle": [
                        {
                          "handler": "throttle",
                          "read_bytes_per_second": 8,
                          "read_burst_size": 8
                        }
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "match": [
                { "not": [ { "quic": {} } ] }
              ],
              "handle": [
                {
                  "handler": "proxy",
                  "upstreams": [
                    { "dial": ["udp/127.0.0.1:9009"] }
                  ]
                }
              ]
            }
          ]
        }
      }
    }
  }
}
EOF
fi

chown -R root:"$CADDY_GROUP" /etc/caddy
chmod 0750 /etc/caddy
chmod 0640 "$CADDY_CONF"

cat >"$CADDY_SERVICE" <<EOF
[Unit]
Description=Caddy layer4 TCP+UDP 443 SNI proxy
After=network.target

[Service]
User=${CADDY_USER}
Group=${CADDY_GROUP}

StateDirectory=caddy
Environment=HOME=/var/lib/caddy
Environment=XDG_CONFIG_HOME=/var/lib/caddy/.config

ExecStart=${CADDY_BIN} run --config ${CADDY_CONF}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144

Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$CADDY_SERVICE"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl restart "$SERVICE_NAME"

echo "caddy-l4 installed: $TAG"
echo
echo "=== caddy-l4 binary version ==="
if ! "${CADDY_BIN}" version 2>/dev/null; then
  "${CADDY_BIN}" --version 2>/dev/null || true
fi
