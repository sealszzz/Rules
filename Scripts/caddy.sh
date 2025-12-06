#!/usr/bin/env bash
# caddy-l4 UDP 443 SNI 分流到 TUIC + Juicity
set -euo pipefail

# ===== 可调参数 =====
: "${TUIC_PORT:=4443}"
: "${JUICITY_PORT:=5443}"
: "${TUIC_SNI:=www.tuic.com}"
: "${JUICITY_SNI:=www.juicity.com}"

: "${CADDY_USER:=caddy}"
: "${CADDY_GROUP:=caddy}"
: "${CADDY_BIN:=/usr/local/bin/caddy-l4}"
: "${CADDY_CONF:=/etc/caddy/caddy.json}"
: "${CADDY_SERVICE:=/etc/systemd/system/caddy-l4.service}"

export DEBIAN_FRONTEND=noninteractive

echo "[*] 安装基础依赖..."
apt update
apt install -y --no-install-recommends \
  debian-keyring debian-archive-keyring apt-transport-https \
  curl ca-certificates gpg

# ===== 安装 xcaddy（官方包） =====
# 文档参考：官方 xcaddy Debian 仓库  [oai_citation:2‡GitHub](https://github.com/caddyserver/xcaddy?utm_source=chatgpt.com)
if ! command -v xcaddy >/dev/null 2>&1; then
  echo "[*] 安装 xcaddy..."
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/gpg.key' \
    | gpg --dearmor >/usr/share/keyrings/caddy-xcaddy-archive-keyring.gpg

  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-xcaddy.list

  apt update
  apt install -y xcaddy
fi

# ===== 编译带 layer4 插件的 Caddy =====
# 插件：github.com/mholt/caddy-l4  [oai_citation:3‡GitHub](https://github.com/mholt/caddy-l4?utm_source=chatgpt.com)
echo "[*] 使用 xcaddy 编译带 layer4 的 Caddy..."
xcaddy build \
  --with github.com/mholt/caddy-l4 \
  --output "${CADDY_BIN}"

chmod +x "${CADDY_BIN}"

# ===== 创建用户和目录 =====
echo "[*] 创建 caddy 用户/组与配置目录..."
getent group "${CADDY_GROUP}" >/dev/null || groupadd --system "${CADDY_GROUP}"
if ! id -u "${CADDY_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home \
    --gid "${CADDY_GROUP}" \
    --shell /usr/sbin/nologin \
    "${CADDY_USER}"
fi

mkdir -p /etc/caddy
chown -R "${CADDY_USER}:${CADDY_GROUP}" /etc/caddy

# ===== 写入 caddy.json（UDP 443 SNI → TUIC / Juicity） =====
echo "[*] 写入 ${CADDY_CONF}..."

cat > "${CADDY_CONF}" <<EOF
{
  "apps": {
    "layer4": {
      "servers": {
        "udpsni": {
          "listen": ["udp/:443"],
          "routes": [
            {
              "match": [
                {
                  "quic": {
                    "sni": ["${TUIC_SNI}"]
                  }
                }
              ],
              "handle": [
                {
                  "handler": "proxy",
                  "upstreams": [
                    {
                      "dial": ["udp/127.0.0.1:${TUIC_PORT}"]
                    }
                  ]
                }
              ]
            },
            {
              "match": [
                {
                  "quic": {
                    "sni": ["${JUICITY_SNI}"]
                  }
                }
              ],
              "handle": [
                {
                  "handler": "proxy",
                  "upstreams": [
                    {
                      "dial": ["udp/127.0.0.1:${JUICITY_PORT}"]
                    }
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

chown "${CADDY_USER}:${CADDY_GROUP}" "${CADDY_CONF}"
chmod 640 "${CADDY_CONF}"

# ===== systemd 服务 =====
echo "[*] 写入 ${CADDY_SERVICE}..."

cat > "${CADDY_SERVICE}" <<EOF
[Unit]
Description=Caddy layer4 UDP 443 SNI proxy (TUIC + Juicity)
After=network.target

[Service]
User=${CADDY_USER}
Group=${CADDY_GROUP}
ExecStart=${CADDY_BIN} run --config ${CADDY_CONF} --adapter json
Restart=on-failure
RestartSec=5s

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# ===== 启动服务 =====
echo "[*] 重新加载 systemd & 启动 caddy-l4..."
systemctl daemon-reload
systemctl enable --now caddy-l4

echo "[+] 完成！现在 UDP/443 由 Caddy 接管，并按 SNI 分流："
echo "    ${TUIC_SNI}  →  udp/127.0.0.1:${TUIC_PORT} (TUIC)"
echo "    ${JUICITY_SNI} →  udp/127.0.0.1:${JUICITY_PORT} (Juicity)"
EOF
