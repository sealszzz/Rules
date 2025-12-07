#!/usr/bin/env bash
# caddy-l4 UDP 443 SNI 分流到 TUIC + Juicity（使用你上传的二进制）
set -euo pipefail

# ===== 可调参数 =====
: "${TUIC_PORT:=4443}"
: "${JUICITY_PORT:=5443}"
: "${TUIC_SNI:=tuic.example.com}"
: "${JUICITY_SNI:=jc.example.com}"

: "${CADDY_USER:=caddy}"
: "${CADDY_GROUP:=caddy}"
: "${CADDY_BIN:=/usr/local/bin/caddy-l4}"
: "${CADDY_CONF:=/etc/caddy/caddy.json}"
: "${CADDY_SERVICE:=/etc/systemd/system/caddy-l4.service}"

export DEBIAN_FRONTEND=noninteractive

echo "[*] 安装基础依赖（不含 Go/xcaddy）..."
apt update
apt install -y --no-install-recommends \
  debian-keyring debian-archive-keyring apt-transport-https \
  curl ca-certificates gpg

# ===== 不再编译！只检查上传的二进制是否存在，然后赋权 =====
if [ ! -f "${CADDY_BIN}" ]; then
  echo "FATAL: ${CADDY_BIN} 不存在！"
  echo "请先把 caddy-l4 上传到 ${CADDY_BIN}"
  exit 1
fi

chmod +x "${CADDY_BIN}"
echo "[*] 检测到已上传的 Caddy，并已赋予可执行权限：${CADDY_BIN}"

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

# ===== 写入 caddy.json 配置 =====
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
                    { "dial": ["udp/127.0.0.1:${TUIC_PORT}"] }
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
                    { "dial": ["udp/127.0.0.1:${JUICITY_PORT}"] }
                  ]
                }
              ]
            },
            {
              "match": [
                { "quic": {} }
              ],
              "handle": [
                { "handler": "echo" }
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

# ===== 写入 systemd =====
echo "[*] 写入 ${CADDY_SERVICE}..."

cat > "${CADDY_SERVICE}" <<EOF
[Unit]
Description=Caddy layer4 UDP 443 SNI proxy (TUIC + Juicity)
After=network.target

[Service]
User=${CADDY_USER}
Group=${CADDY_GROUP}
ExecStart=${CADDY_BIN} run --config ${CADDY_CONF}
Restart=on-failure
RestartSec=5

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# ===== 启动 =====
echo "[*] 重新加载 systemd & 启动 caddy-l4..."
systemctl daemon-reload
systemctl enable --now caddy-l4

echo
echo "[+] 部署完成！UDP/443 已由 Caddy 接管，按 SNI 分流："
echo "    ${TUIC_SNI}     → udp/127.0.0.1:${TUIC_PORT} (TUIC)"
echo "    ${JUICITY_SNI}  → udp/127.0.0.1:${JUICITY_PORT} (Juicity)"
echo
echo "注意：请确保 tuic / juicity 不再直接监听 UDP 443。"
