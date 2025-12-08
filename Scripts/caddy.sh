#!/usr/bin/env bash
# caddy-l4 UDP 443 SNI 分流到 TUIC + Juicity
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

echo "[*] 安装基础依赖..."
apt update
apt install -y --no-install-recommends \
  debian-keyring debian-archive-keyring apt-transport-https \
  curl ca-certificates gpg golang-go

# ===== 安装 xcaddy（官方包） =====
if ! command -v xcaddy >/dev/null 2>&1; then
  echo "[*] 安装 xcaddy..."
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/gpg.key' \
    | gpg --dearmor >/usr/share/keyrings/caddy-xcaddy-archive-keyring.gpg

  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-xcaddy.list

  apt update
  apt install -y xcaddy
fi

# ===== 准备 Go 的临时/缓存目录，避免挤爆 /tmp =====
BUILD_TMP_ROOT="/var/tmp/go-build"
BUILD_CACHE_ROOT="/var/tmp/go-cache"

mkdir -p "$BUILD_TMP_ROOT" "$BUILD_CACHE_ROOT"
chmod 700 "$BUILD_TMP_ROOT" "$BUILD_CACHE_ROOT"

export TMPDIR="$BUILD_TMP_ROOT"
export GOCACHE="$BUILD_CACHE_ROOT"

# ===== 编译带 layer4 插件的 Caddy =====
echo "[*] 使用 xcaddy 编译带 layer4 的 Caddy..."
xcaddy build \
  --with github.com/mholt/caddy-l4 \
  --output "${CADDY_BIN}"

chmod +x "${CADDY_BIN}"
echo "[*] 已更新二进制: ${CADDY_BIN}"

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

# ===== 写入 caddy.json（仅在不存在时创建） =====
if [ -e "${CADDY_CONF}" ]; then
  echo "[*] 检测到已有配置 ${CADDY_CONF}，跳过覆盖（保留你现有的配置）。"
else
  echo "[*] 写入默认配置到 ${CADDY_CONF}..."

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
            },
            {
              "match": [
                {
                  "quic": {}
                }
              ],
              "handle": [
                {
                  "handler": "echo"
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
fi

# ===== systemd 服务（仅在不存在时创建） =====
if [ -e "${CADDY_SERVICE}" ]; then
  echo "[*] 检测到已有 systemd 服务 ${CADDY_SERVICE}，跳过覆盖。"
else
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
RestartSec=5s

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
fi

# ===== 启动 / 重启服务 =====
echo "[*] 重新加载 systemd & 启动/重启 caddy-l4..."
systemctl daemon-reload
systemctl enable --now caddy-l4
systemctl restart caddy-l4 || true

echo
echo "[+] 完成！现在 UDP/443 由 Caddy 接管，并按 SNI 分流："
echo "    ${TUIC_SNI}     →  udp/127.0.0.1:${TUIC_PORT} (TUIC)"
echo "    ${JUICITY_SNI}  →  udp/127.0.0.1:${JUICITY_PORT} (Juicity)"
echo
echo "注意："
echo "  - 首次运行会生成默认配置和服务文件；"
echo "  - 以后再次运行只会更新 ${CADDY_BIN}，不会覆盖你已经手改过的配置和 unit。"
