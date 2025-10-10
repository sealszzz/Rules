#!/usr/bin/env bash
set -e

SS_USER="ssrust"
SS_DIR="/etc/ssrust"
SS_CONFIG="$SS_DIR/config.json"
SS_BIN="/usr/local/bin/ssserver"
SERVICE_FILE="/etc/systemd/system/ssrust.service"

get_latest_version() {
    curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep tag_name | cut -d '"' -f4
}

install_or_upgrade() {
    LATEST=$(get_latest_version)
    [ -z "$LATEST" ] && { echo "获取最新版本失败"; return; }
    echo ">>> 最新版本: $LATEST"

    if [ -x "$SS_BIN" ]; then
        CURRENT=$($SS_BIN --version | awk '{print $2}')
    else
        CURRENT="none"
    fi

    if [ "$CURRENT" = "$LATEST" ]; then
        echo ">>> 已是最新版本 ($CURRENT)"
        return
    fi

    apt update && apt install -y wget xz-utils openssl jq

    echo ">>> 下载并安装 $LATEST ..."
    wget -qO- https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST}/shadowsocks-${LATEST}.x86_64-unknown-linux-gnu.tar.xz | tar -xJ -C /tmp
    mv /tmp/ssserver $SS_BIN
    chmod +x $SS_BIN

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
        systemctl daemon-reload
        systemctl enable --now ssrust
        echo ">>> 安装完成! 默认端口 2048"
    else
        echo ">>> 升级完成，重启服务..."
        systemctl daemon-reload
        systemctl restart ssrust
    fi
}

show_status() {
    if [ ! -x "$SS_BIN" ]; then
        echo ">>> 未安装"
        return
    fi
    systemctl is-active --quiet ssrust && STATUS="运行中" || STATUS="未运行"
    VERSION=$($SS_BIN --version | awk '{print $2}')
    echo ">>> 状态: $STATUS"
    echo ">>> 版本: $VERSION"
    if [ -f "$SS_CONFIG" ]; then
        PORT=$(jq -r '.server_port' $SS_CONFIG)
        PASS=$(jq -r '.password' $SS_CONFIG)
        METHOD=$(jq -r '.method' $SS_CONFIG)
        echo ">>> 端口: $PORT"
        echo ">>> 密码: $PASS"
        echo ">>> 加密: $METHOD"
    fi
}

config_edit() {
    if [ ! -f "$SS_CONFIG" ]; then
        echo ">>> 未找到配置文件，请先安装"
        return
    fi
    CURRENT_PORT=$(jq -r '.server_port' $SS_CONFIG)
    CURRENT_PASS=$(jq -r '.password' $SS_CONFIG)
    CURRENT_METHOD=$(jq -r '.method' $SS_CONFIG)

    read -p "新端口 (当前 $CURRENT_PORT): " NEW_PORT
    [ -z "$NEW_PORT" ] && NEW_PORT=$CURRENT_PORT
    read -p "新密码 (回车保持不变): " NEW_PASS
    [ -z "$NEW_PASS" ] && NEW_PASS=$CURRENT_PASS
    echo "常用加密: 2022-blake3-aes-128-gcm / 2022-blake3-aes-256-gcm"
    read -p "新加密 (当前 $CURRENT_METHOD): " NEW_METHOD
    [ -z "$NEW_METHOD" ] && NEW_METHOD=$CURRENT_METHOD

    cat > $SS_CONFIG <<EOF
{
  "server": "[::]",
  "server_port": $NEW_PORT,
  "password": "$NEW_PASS",
  "method": "$NEW_METHOD",
  "mode": "tcp_and_udp",
  "timeout": 300
}
EOF
    chown $SS_USER:$SS_USER $SS_CONFIG
    chmod 640 $SS_CONFIG
    systemctl restart ssrust
    echo ">>> 配置已更新并重启服务"
}

uninstall_ssrust() {
    systemctl stop ssrust 2>/dev/null || true
    systemctl disable ssrust 2>/dev/null || true
    rm -f $SS_BIN $SERVICE_FILE
    rm -rf $SS_DIR
    id -u $SS_USER >/dev/null 2>&1 && userdel -r $SS_USER || true
    systemctl daemon-reload
    echo ">>> 已卸载"
}

# ---------------- 菜单 ----------------
while true; do
    clear
    echo "==============================="
    echo " Shadowsocks-Rust 管理界面"
    echo "==============================="
    echo "1) 安装 / 升级"
    echo "2) 查看状态"
    echo "3) 修改配置"
    echo "4) 卸载"
    echo "5) 退出"
    echo "==============================="
    read -p "请选择操作 [1-5]: " choice

    case $choice in
        1) install_or_upgrade ;;
        2) show_status ;;
        3) config_edit ;;
        4) uninstall_ssrust ;;
        5) echo "退出"; exit 0 ;;
        *) echo "无效选项";;
    esac
    echo
    read -p "按回车键继续..." dummy
done
