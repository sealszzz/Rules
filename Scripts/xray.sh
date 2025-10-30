#!/usr/bin/env bash
set -euo pipefail

# ========= 可调路径/参数（如无必要别改）=========
: "${XRAY_PORT:=8888}"
: "${XRAY_SNI:=www.cloudflare.com}"      # 伪装域名 / ServerName
: "${XRAY_DEST:=www.cloudflare.com:443}" # Reality 回源目标
: "${XRAY_USER:=xray}"
: "${XRAY_GROUP:=xray}"

XRAY_STATE_DIR="/var/lib/xray"
XRAY_CONF_DIR="/etc/xray"
XRAY_CONF_FILE="${XRAY_CONF_DIR}/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="/etc/systemd/system/xray.service"

export DEBIAN_FRONTEND=noninteractive

# ========= 依赖 =========
apt update
apt install -y --no-install-recommends curl jq ca-certificates uuid-runtime unzip

# ========= 系统用户与目录（第一次会创建，之后复用）=========
getent group "$XRAY_GROUP" >/dev/null || groupadd --system "$XRAY_GROUP"
id -u "$XRAY_USER" >/dev/null 2>&1 || \
  useradd --system -g "$XRAY_GROUP" -M -d "$XRAY_STATE_DIR" -s /usr/sbin/nologin "$XRAY_USER"

install -d -o "$XRAY_USER" -g "$XRAY_GROUP" -m 750 "$XRAY_STATE_DIR"
install -d -o root        -g "$XRAY_GROUP" -m 750 "$XRAY_CONF_DIR"

# ========= 选取 release 里的正确资产 (glibc 优先) =========
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)  MACHINE="64" ;;
  aarch64|arm64) MACHINE="arm64-v8a" ;;
  *) echo "不支持的架构: $arch（仅 x86_64 / aarch64）" >&2; exit 1 ;;
esac

echo "[*] 获取 Xray 最新 Release 信息..."
rel_json="$(curl -fsSL --retry 3 --retry-delay 1 https://api.github.com/repos/XTLS/Xray-core/releases/latest)"
[ -n "$rel_json" ] || { echo "获取 release 信息失败"; exit 1; }
tag="$(echo "$rel_json" | jq -r '.tag_name')"
[ -n "$tag" ] || { echo "无法解析 tag_name"; exit 1; }

zip_name="Xray-linux-${MACHINE}.zip"
dl_url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${zip_name}"
echo "[*] 将安装版本: $tag"
echo "[*] 选择资产:  $zip_name"

# ========= 下载并安装二进制（仅核心，无 geodata）=========
tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

curl -fL "$dl_url" -o "$tmpd/xray.zip"
unzip -q "$tmpd/xray.zip" -d "$tmpd/u"

binpath="$(find "$tmpd/u" -maxdepth 2 -type f -name 'xray' -perm -u+x | head -n1 || true)"
[ -n "$binpath" ] || { echo "未在资产内找到可执行文件 xray"; exit 1; }
install -m 0755 "$binpath" "$XRAY_BIN"

# ========= 首次生成配置（存在则不覆盖）=========
if [ ! -f "$XRAY_CONF_FILE" ]; then
  XRAY_UUID="${XRAY_UUID:-$(uuidgen)}"

  # 生成 Reality 私钥/公钥（用于分享给客户端）
  # 用刚安装的 xray 自带工具生成，避免外部依赖
  mapfile -t KP < <("$XRAY_BIN" x25519 2>/dev/null | awk '/(Private|Public)/{print $3}')
  XRAY_PRIV="${XRAY_PRIV:-${KP[0]:-}}"
  XRAY_PUB="${XRAY_PUB:-${KP[1]:-}}"
  [ -n "${XRAY_PRIV:-}" ] && [ -n "${XRAY_PUB:-}" ] || { echo "生成 Reality 密钥失败"; exit 1; }

  # Reality shortId：8~16位十六进制，给默认 8 字节(16 hex)
  XRAY_SHORTID="${XRAY_SHORTID:-$(openssl rand -hex 8)}"

  cat >"$XRAY_CONF_FILE" <<EOF
{
  "inbounds": [
    {
      "port": ${XRAY_PORT},
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${XRAY_DEST}",
          "xver": 0,
          "serverNames": ["${XRAY_SNI}"],
          "privateKey": "${XRAY_PRIV}",
          "publicKey": "${XRAY_PUB}",
          "shortIds": ["${XRAY_SHORTID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
EOF

  chown root:"$XRAY_GROUP" "$XRAY_CONF_FILE"
  chmod 640           "$XRAY_CONF_FILE"

  echo
  echo "==== 首次配置生成完成 ===="
  echo "UUID:       $XRAY_UUID"
  echo "Reality 公钥(客户端用): $XRAY_PUB"
  echo "Reality 私钥(服务器用): $XRAY_PRIV"
  echo "ShortID:    $XRAY_SHORTID"
  echo "SNI:        $XRAY_SNI"
  echo "回源目标:    $XRAY_DEST"
fi

# ========= systemd service（只在第一次创建）=========
if [ ! -f "$XRAY_SERVICE" ]; then
  cat >"$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray (VLESS+Vision+Reality)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=${XRAY_USER}
Group=${XRAY_GROUP}
Type=simple
UMask=0077
WorkingDirectory=${XRAY_STATE_DIR}
ExecStart=${XRAY_BIN} run -c ${XRAY_CONF_FILE}
Restart=on-failure
RestartSec=3s
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144

[Install]
WantedBy=multi-user.target
EOF
fi

chmod 644 "$XRAY_SERVICE"

# ========= 启动 / 重载 =========
systemctl daemon-reload
if systemctl is-enabled xray >/dev/null 2>&1; then
  systemctl try-reload-or-restart xray || systemctl restart xray
else
  systemctl enable --now xray || true
fi

# ========= 摘要 =========
echo
"$XRAY_BIN" -version 2>/dev/null || true
echo "已安装版本: ${tag}"
echo "配置: $XRAY_CONF_FILE"
echo "二进制: $XRAY_BIN"
echo "服务: $XRAY_SERVICE"
echo "UDP/TCP ${XRAY_PORT} 监听："
ss -Hnplut | grep -E ":${XRAY_PORT}([^0-9]|$)" || echo "未见端口占用（如刚启动可稍等）"
