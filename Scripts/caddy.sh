#!/usr/bin/env bash
# caddy-l4 UDP 443 SNI → TUIC / Juicity 分流
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

echo "[*] 安装基础依赖（非编译环境也安全）..."
apt update
apt install -y --no-install-recommends \
  debian-keyring debian-archive-keyring apt-transport-https \
  curl ca-certificates gpg

# 标记：本次是否编译了新 bin
NEED_BUILD=0
NEED_RESTART=0

# ===== 交互：要不要重新编译 bin？ =====
if [ -x "${CADDY_BIN}" ]; then
  echo "[*] 检测到已存在的二进制: ${CADDY_BIN}"
  read -rp "是否重新编译 caddy-l4？ [y/N]: " ANSWER
  ANSWER=${ANSWER:-N}
  if [[ "${ANSWER}" =~ ^[Yy]$ ]]; then
    NEED_BUILD=1
  else
    echo "[*] 选择不重新编译，使用现有二进制。"
  fi
else
  echo "[!] 未找到 ${CADDY_BIN}，如果不编译，就必须先手动上传该文件。"
  read -rp "是否现在编译 caddy-l4？ [y/N]: " ANSWER
  ANSWER=${ANSWER:-N}
  if [[ "${ANSWER}" =~ ^[Yy]$ ]]; then
    NEED_BUILD=1
  else
    echo "FATAL: 没有 ${CADDY_BIN}，且你选择不编译，本机目前没有可用的 caddy-l4。"
    exit 1
  fi
fi

# ===== 如果需要编译，走一遍 xcaddy build 流程 =====
if [ "${NEED_BUILD}" -eq 1 ]; then
  echo "[*] 安装编译环境 golang-go..."
  apt install -y --no-install-recommends golang-go

  if ! command -v xcaddy >/dev/null 2>&1; then
    echo "[*] 安装 xcaddy..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/gpg.key' \
      | gpg --dearmor >/usr/share/keyrings/caddy-xcaddy-archive-keyring.gpg

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-xcaddy.list

    apt update
    apt install -y xcaddy
  fi

  BUILD_TMP_ROOT="/var/tmp/go-build"
  BUILD_CACHE_ROOT="/var/tmp/go-cache"
  mkdir -p "$BUILD_TMP_ROOT" "$BUILD_CACHE_ROOT"
  chmod 700 "$BUILD_TMP_ROOT" "$BUILD_CACHE_ROOT"
  export TMPDIR="$BUILD_TMP_ROOT"
  export GOCACHE="$BUILD_CACHE_ROOT"

  echo "[*] 使用 xcaddy 编译带 layer4 的 Caddy..."
  xcaddy build \
    --with github.com/mholt/caddy-l4 \
    --output "${CADDY_BIN}"

  chmod +x "${CADDY_BIN}"
  echo "[+] 编译完成: ${CADDY_BIN}"

  NEED_RESTART=1
else
  # 不编译，但要求 bin 必须存在
  if [ ! -f "${CADDY_BIN}" ]; then
    echo "FATAL: 期望使用已有 ${CADDY_BIN}，但文件不存在。"
    exit 1
  fi
  chmod +x "${CADDY_BIN}"
  echo "[*] 使用已有二进制: ${CADDY_BIN}"
fi

# ===== 创建用户和目录 =====
echo "[*] 创建 caddy 用户/组与配置目录..."
getent group "${CADDY_GROUP}" >/dev/null || groupadd --system "${CADDY_GROUP}"

if ! id -u "${CADDY_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home \
    --gid "${CADDY_GROUP}" \
    --shell /usr/sbin/nologin \
    "${CADDY_USER}"
fi

HOME_DIR="/home/${CADDY_USER}"
mkdir -p "${HOME_DIR}/.config/caddy"
chown -R "${CADDY_USER}:${CADDY_GROUP}" "${HOME_DIR}"

mkdir -p /etc/caddy
chown -R "${CADDY_USER}:${CADDY_GROUP}" /etc/caddy

# ===== 写配置（仅第一次创建） =====
if [ -e "${CADDY_CONF}" ]; then
  echo "[*] 检测到已有配置 ${CADDY_CONF}，跳过覆盖。"
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
              "match": [{ "quic": { "sni": ["${TUIC_SNI}"] }}],
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
              "match": [{ "quic": { "sni": ["${JUICITY_SNI}"] }}],
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
              "match": [{ "quic": {} }],
              "handle": [{ "handler": "echo" }]
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

# ===== 写 systemd 单元（仅第一次创建） =====
if [ -e "${CADDY_SERVICE}" ]; then
  echo "[*] 检测到已有 systemd 单元 ${CADDY_SERVICE}，跳过覆盖。"
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

# ===== 启动 / 重启逻辑 =====
echo "[*] 重新加载 systemd..."
systemctl daemon-reload
systemctl enable caddy-l4 >/dev/null 2>&1 || true

if [ "${NEED_RESTART}" -eq 1 ]; then
  echo "[*] 本次编译了新二进制 → 重启 caddy-l4..."
  systemctl restart caddy-l4
else
  # 没编译新 bin：仅在未运行时启动
  if systemctl is-active --quiet caddy-l4; then
    echo "[*] caddy-l4 已在运行，保持现状，不做重启。"
  else
    echo "[*] caddy-l4 未运行，尝试启动..."
    systemctl start caddy-l4
  fi
fi

echo
echo "[+] 完成！UDP/443 已由 Caddy 接管，并按 SNI 分流："
echo "    ${TUIC_SNI}    → udp/127.0.0.1:${TUIC_PORT} (TUIC)"
echo "    ${JUICITY_SNI} → udp/127.0.0.1:${JUICITY_PORT} (Juicity)"
echo
echo "使用提示："
echo "  - 首次用“编译机”跑时，可以直接选 Y，让它编译出 ${CADDY_BIN}"
echo "  - 在其他 VPS 上，只要先上传同名 bin，运行脚本时选 N 即可完成部署"
