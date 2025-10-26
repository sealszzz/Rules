bash -c '
set -euo pipefail

# ====== 可调参数（可通过环境变量覆盖） ======
: "${BIND_PORT:=443}"                   # 服务监听 UDP 端口
: "${UPSTREAM_HOST:=www.debian.org}"    # 伪装用真实 TLS 域名（需可连通）
: "${UPSTREAM_PORT:=443}"               # 上游端口，通常 443
: "${LOG_LEVEL:=info}"                  # trace / debug / info / warn / error

# 账号（如需固定，可预先导出 USER1/PASS1）
: "${PASS1:=$(openssl rand -hex 16)}"   # 16 bytes -> 32 hex (128-bit)
: "${USER1:=$(openssl rand -hex 8)}"    # 8 bytes -> 16 hex (64-bit)

# ====== 基础依赖 ======
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends curl ca-certificates openssl

# ====== 系统用户与目录 ======
getent group shadowquic >/dev/null || groupadd --system shadowquic
id -u shadowquic >/dev/null 2>&1 || useradd --system -g shadowquic -M -d /var/lib/shadowquic -s /usr/sbin/nologin shadowquic
install -d -o shadowquic -g shadowquic -m 750 /var/lib/shadowquic
install -d -o root -g shadowquic -m 750 /etc/shadowquic

# ====== 架构检测：GNU/glibc 优先，musl 兜底（仅列常见 VPS 架构） ======
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)  ASSET="shadowquic-x86_64-linux";  FALLBACK="shadowquic-x86_64-linux-musl" ;;
  aarch64|arm64) ASSET="shadowquic-aarch64-linux"; FALLBACK="shadowquic-aarch64-linux-musl" ;;
  *) echo "不支持的架构: $arch（目前脚本仅适配 x86_64 / aarch64）" >&2; exit 1 ;;
esac

# ====== 下载最新 release：先 GNU/glibc，再 musl ======
cd /tmp
URL_BASE="https://github.com/spongebob888/shadowquic/releases/latest/download"
echo "下载 ${ASSET} （GNU/glibc 优先）..."
if ! curl -fL -o shadowquic "$URL_BASE/${ASSET}"; then
  echo "glibc 资产不存在或下载失败，回退到 musl：${FALLBACK}"
  curl -fL -o shadowquic "$URL_BASE/${FALLBACK}"
fi
chmod +x shadowquic
mv shadowquic /usr/local/bin/shadowquic

# ====== 生成服务端配置（YAML）=====
cat >/etc/shadowquic/server.yaml <<EOF
inbound:
  type: shadowquic
  bind-addr: "[::]:${BIND_PORT}"
  users:
    - password: "${PASS1}"
      username: "${USER1}"
  jls-upstream:
    addr: "${UPSTREAM_HOST}:${UPSTREAM_PORT}"
  alpn: ["h3"]
  congestion-control: bbr
  zero-rtt: true
  # initial-mtu: 1400   # 可选：高丢包网络建议启用
  # min-mtu: 1290       # 可选：需小于 initial-mtu
outbound:
  type: direct
  dns-strategy: prefer-ipv4   # 或 prefer-ipv6 / ipv4-only / ipv6-only
log-level: "${LOG_LEVEL}"
EOF

# 权限：root 写，组读
chown root:shadowquic /etc/shadowquic/server.yaml
chmod 640 /etc/shadowquic/server.yaml

# ====== systemd 单元 ======
cat >/etc/systemd/system/shadowquic.service <<EOF
[Unit]
Description=ShadowQUIC Server (glibc-first)
Documentation=https://github.com/spongebob888/shadowquic
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=shadowquic
Group=shadowquic
Type=simple
UMask=0077
WorkingDirectory=/var/lib/shadowquic
ExecStart=/usr/local/bin/shadowquic -c /etc/shadowquic/server.yaml
Restart=on-failure
RestartSec=3s
LimitNOFILE=262144
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now shadowquic

echo
echo "=== 安装完成（GNU/glibc 优先版本） ==="
echo "监听端口(UDP)：${BIND_PORT}"
echo "上游伪装：${UPSTREAM_HOST}:${UPSTREAM_PORT}"
echo "用户1：${USER1} / ${PASS1}"
echo
echo "状态："
systemctl --no-pager --full status shadowquic || true
echo
echo "UDP/${BIND_PORT} 监听检查："
ss -u -lpn | grep ":${BIND_PORT} " || echo "未见 UDP/${BIND_PORT} 监听/占用（若刚启动，稍等 1~2 秒再查）"
'
