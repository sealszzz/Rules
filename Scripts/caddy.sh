#!/usr/bin/env bash
# caddy-l4 UDP 443 SNI → TUIC / Juicity 分流（从 GitHub Releases 下载二进制）
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

# 你的 GitHub 仓库（可以改成别的）
: "${CADDY_REPO:=sealszzz/Caddy}"

export DEBIAN_FRONTEND=noninteractive

echo "[*] 安装基础依赖..."
apt update
apt install -y --no-install-recommends \
  curl ca-certificates tar

# ===== 检测架构，映射到 amd64 / arm64 =====
detect_arch() {
  local a
  a=$(dpkg --print-architecture 2>/dev/null || echo "")
  case "$a" in
    amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *)
      # 兜底用 uname
      a=$(uname -m)
      case "$a" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)
          echo "FATAL: 不支持的架构: $a" >&2
          exit 1
          ;;
      esac
      ;;
  esac
}

ARCH="$(detect_arch)"
echo "[*] 检测到架构: ${ARCH}"

# ===== 解析你仓库的最新 tag =====
echo "[*] 获取 ${CADDY_REPO} 最新 Release tag..."
LATEST_URL=$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
  "https://github.com/${CADDY_REPO}/releases/latest")
TAG="${LATEST_URL##*/}"   # 例如 v2.9.1
echo "[*] 最新 tag: ${TAG}"

ASSET_NAME="caddy-l4-linux-${ARCH}-${TAG}.tar.gz"
ASSET_URL="https://github.com/${CADDY_REPO}/releases/download/${TAG}/${ASSET_NAME}"

TMP_DIR=$(mktemp -d /tmp/caddy-l4.XXXXXX)
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "[*] 下载二进制压缩包: ${ASSET_URL}"
if ! curl -fL -o "${TMP_DIR}/${ASSET_NAME}" "${ASSET_URL}"; then
  echo "FATAL: 下载失败: ${ASSET_URL}"
  exit 1
fi

echo "[*] 解压..."
tar -xzf "${TMP_DIR}/${ASSET_NAME}" -C "${TMP_DIR}"

BIN_SRC="${TMP_DIR}/caddy-l4-linux-${ARCH}"
if [ ! -f "${BIN_SRC}" ]; then
  echo "FATAL: 压缩包内未找到二进制: ${BIN_SRC}"
  exit 1
fi

echo "[*] 安装二进制到 ${CADDY_BIN}..."
install -m 0755 "${BIN_SRC}" "${CADDY_BIN}"

NEED_RESTART=1

# ===== 创建用户和目录（只做一次） =====
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

if systemctl is-active --quiet caddy-l4; then
  echo "[*] caddy-l4 已在运行，重启以加载新二进制..."
  systemctl restart caddy-l4
else
  echo "[*] caddy-l4 未运行，尝试启动..."
  systemctl start caddy-l4
fi

echo
echo "[+] 完成！"
echo "    - 使用的仓库: ${CADDY_REPO}"
echo "    - 使用的版本: ${TAG}"
echo "    - 二进制:      ${CADDY_BIN}"
echo
echo "UDP/443 分流："
echo "    ${TUIC_SNI}    → udp/127.0.0.1:${TUIC_PORT} (TUIC)"
echo "    ${JUICITY_SNI} → udp/127.0.0.1:${JUICITY_PORT} (Juicity)"
