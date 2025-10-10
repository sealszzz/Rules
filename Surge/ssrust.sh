#!/usr/bin/env bash
set -e

# 基础参数
SS_USER="ssrust"
SS_DIR="/etc/ssrust"
SS_CONFIG="$SS_DIR/config.json"
SS_BIN="/usr/local/bin/ssserver"
SERVICE_FILE="/etc/systemd/system/ssrust.service"

# 从 GitHub 获取最新版本号
LATEST=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep tag_name | cut -d '"' -f4)
[ -z "$LATEST" ] && { echo "获取最新版本失败，请检查网络/GitHub API"; exit 1; }

echo ">>> 最新版本: $LATEST"

# 如果已安装，获取当前版本
if [ -x "$SS_BIN" ]; then
    CURRENT=$($SS_BIN --version | awk '{print $2}')
    echo ">>> 当前已安装版本: $CURRENT"
else
    CURRENT="none"
    echo ">>> 当前未安装"
fi

# 如果版本相同，退出
if [ "$CURRENT" = "$LATEST" ]; then
    echo ">>> 已是最新版本，无需更新"
    exit 0
fi

# 安装依赖
apt update && apt install -y wget xz-utils openssl

echo ">>> 下载 Shadowsocks-Rust $LATEST ..."
wget -qO- https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST}/shadowsocks-${LATEST}.x86_64-unknown-linux-gnu.tar.xz | tar -xJ -C /tmp

echo ">>> 安装二进制..."
mv /tmp/ssserver $SS_BIN
chmod +x $SS_BIN

# 如果是首次安装，创建用户和配置文件、systemd 服务
if [ "$CURRENT" = "none" ]; then
    echo ">>> 首次安装，创建用户和配置..."
    id -u $SS_USER >/dev/null 2>&1 || useradd -r -M -d $SS_DIR -s /usr/sbin/nologin $SS_USER
    mkdir -p $SS_DIR

    PASSWORD=$(openssl rand -base64 16)
    cat > $SS_CONFIG <<EOF
{
  "server": "[::]",
  "server_port": 2048,
  "password": "$PASSWORD",
  "method": "2022-blake3-aes-128-gcm",
  "mode": "tcp_and_udp",
  "timeout": 300
}
EOF
    chown -R $SS_USER:$SS_USER $SS_DIR
    chmod 640 $SS_CONFIG

    echo ">>> 写入 systemd 服务..."
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=Shadowsocks-Rust Server
Documentation=https://github.com/shadowsocks/shadowsocks-rust
After=network-online.target nss-lookup.target

[Service]
Type=simple
ExecStart=$SS_BIN --config $SS_CONFIG
WorkingDirectory=$SS_DIR
User=$SS_USER
Group=$SS_USER
UMask=0077

NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    echo ">>> 启动并设置开机自启..."
    systemctl daemon-reload
    systemctl enable --now ssrust

    echo "----------------------------------"
    echo "首次安装完成!"
    echo "端口: 2048"
    echo "密码: $PASSWORD"
    echo "加密: 2022-blake3-aes-128-gcm"
    echo "配置文件: $SS_CONFIG"
    echo "systemctl status ssrust  查看状态"
    echo "----------------------------------"
else
    echo ">>> 检测到有新版本，执行升级..."
    systemctl daemon-reload
    systemctl restart ssrust
    echo ">>> 已升级到 $LATEST"
fi
