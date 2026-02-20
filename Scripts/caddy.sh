#!/usr/bin/env bash
set -euo pipefail

: "${CADDY_USER:=caddy}"
: "${CADDY_GROUP:=caddy}"
: "${CADDY_BIN:=/usr/local/bin/caddy}"
: "${CADDY_CONF:=/etc/caddy/caddy.json}"
: "${CADDY_SERVICE:=/etc/systemd/system/caddy.service}"
: "${CADDY_REPO:=sealszzz/Caddy}"
: "${SERVICE_NAME:=caddy}"

# >>> ADDED (naive Caddyfile only; not used by service)
: "${CADDYFILE_NAIVE:=/etc/caddy/Caddyfile}"
: "${CERT_FILE:=/etc/tls/cert.pem}"
: "${KEY_FILE:=/etc/tls/key.pem}"
: "${NAIVE_WEBROOT:=/var/www/html}"
: "${NAIVE_USER:=}"
: "${NAIVE_PASS:=}"
# <<< ADDED

export DEBIAN_FRONTEND=noninteractive
[ "$(id -u)" -eq 0 ] || { echo "FATAL: run as root"; exit 1; }

apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates tar openssl >/dev/null

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
  amd64|x86_64) ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "FATAL: unsupported arch"; exit 1 ;;
esac

LATEST_URL="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/${CADDY_REPO}/releases/latest")"
TAG="${LATEST_URL##*/}"
[ -n "$TAG" ] || { echo "FATAL: failed to get tag"; exit 1; }

ASSET="caddy-linux-${ARCH}-${TAG}.tar.gz"
URL="https://github.com/${CADDY_REPO}/releases/download/${TAG}/${ASSET}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 3 --retry-delay 1 -o "$TMP/$ASSET" "$URL"
tar -xzf "$TMP/$ASSET" -C "$TMP"

[ -f "$TMP/caddy-linux-${ARCH}" ] || { echo "FATAL: missing binary in tar"; exit 1; }
install -m 0755 "$TMP/caddy-linux-${ARCH}" "$CADDY_BIN"

getent group "$CADDY_GROUP" >/dev/null || groupadd --system "$CADDY_GROUP"
id -u "$CADDY_USER" >/dev/null 2>&1 || useradd --system --no-create-home --gid "$CADDY_GROUP" --shell /usr/sbin/nologin "$CADDY_USER"

install -d -o root -g "$CADDY_GROUP" -m 0750 /etc/caddy

# >>> ADDED (rebuild decoy webroot contents)
install -d -o root -g root -m 0755 "$NAIVE_WEBROOT"
find "$NAIVE_WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cat >"$NAIVE_WEBROOT/index.html" <<'EOF'
<!doctype html>
<meta charset="utf-8">
<title>Welcome</title>
<script>
  location.replace("/");
</script>
EOF
# <<< ADDED

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

# >>> ADDED (generate Naive Caddyfile; not added to service)
[ -f "$CERT_FILE" ] || { echo "FATAL: missing cert file: $CERT_FILE"; exit 1; }
[ -f "$KEY_FILE" ] || { echo "FATAL: missing key file: $KEY_FILE"; exit 1; }

if [ -z "$NAIVE_USER" ]; then
  NAIVE_USER="naive$(openssl rand -hex 3)"
fi
if [ -z "$NAIVE_PASS" ]; then
  NAIVE_PASS="$(openssl rand -hex 16)"
fi

cat >"$CADDYFILE_NAIVE" <<EOF
{
	admin off
	auto_https off
	order forward_proxy before file_server
	servers {
		protocols h3
	}
}

#:9005 {
#	bind 127.0.0.1
#	tls ${CERT_FILE} ${KEY_FILE}

:443, www.example.com {
	tls ${CERT_FILE} ${KEY_FILE}

	forward_proxy {
		basic_auth ${NAIVE_USER} ${NAIVE_PASS}
		hide_ip
		hide_via
		probe_resistance
	}

	file_server {
		root ${NAIVE_WEBROOT}
	}
}
EOF
# <<< ADDED

chown -R root:"$CADDY_GROUP" /etc/caddy
chmod 0750 /etc/caddy
chmod 0640 "$CADDY_CONF"

# >>> ADDED (Caddyfile permissions)
chown root:"$CADDY_GROUP" "$CADDYFILE_NAIVE"
chmod 0640 "$CADDYFILE_NAIVE"
# <<< ADDED

cat >"$CADDY_SERVICE" <<EOF
[Unit]
Description=Caddy
After=network.target network-online.target
Requires=network-online.target

[Service]
User=${CADDY_USER}
Group=${CADDY_GROUP}

StateDirectory=caddy
Environment=HOME=/var/lib/caddy
Environment=XDG_CONFIG_HOME=/var/lib/caddy/.config

ExecStart=${CADDY_BIN} run --config ${CADDY_CONF}
ExecReload=${CADDY_BIN} reload --config ${CADDY_CONF}
TimeoutStopSec=5s

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

LimitNOFILE=262144
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$CADDY_SERVICE"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl restart "$SERVICE_NAME"

echo "caddy installed: $TAG"
echo
echo "=== caddy binary version ==="
if ! "${CADDY_BIN}" version 2>/dev/null; then
  "${CADDY_BIN}" --version 2>/dev/null || true
fi
