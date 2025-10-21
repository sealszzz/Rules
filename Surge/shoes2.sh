#!/bin/bash

# Shoes TUIC v5 一键安装脚本

# 适用于 x86-64 Linux VPS

set -e

RED=’\033[0;31m’
GREEN=’\033[0;32m’
YELLOW=’\033[1;33m’
NC=’\033[0m’

echo -e “${GREEN}================================${NC}”
echo -e “${GREEN}Shoes TUIC v5 一键安装脚本${NC}”
echo -e “${GREEN}================================${NC}”

# 检查是否为 root 用户

if [ “$EUID” -ne 0 ]; then
echo -e “${RED}请使用 root 权限运行此脚本${NC}”
exit 1
fi

# 检查系统架构

ARCH=$(uname -m)
if [ “$ARCH” != “x86_64” ]; then
echo -e “${RED}此脚本仅支持 x86-64 架构，当前架构: $ARCH${NC}”
exit 1
fi

# 配置参数

SHOES_VERSION=“0.1.7”
SHOES_URL=“https://github.com/cfal/shoes/releases/download/v${SHOES_VERSION}/shoes-v${SHOES_VERSION}-x86_64-unknown-linux-gnu.tar.gz”
INSTALL_DIR=”/opt/shoes”
CONFIG_DIR=”/etc/shoes”
CERT_DIR=”/etc/tls”
SERVICE_FILE=”/etc/systemd/system/shoes.service”

# 检查证书是否存在

echo -e “${YELLOW}检查证书文件…${NC}”
if [ ! -f “$CERT_DIR/cert.pem” ] || [ ! -f “$CERT_DIR/key.pem” ]; then
echo -e “${RED}错误: 证书文件不存在！${NC}”
echo -e “${RED}请确保以下文件存在:${NC}”
echo -e “${RED}  - $CERT_DIR/cert.pem${NC}”
echo -e “${RED}  - $CERT_DIR/key.pem${NC}”
exit 1
fi
echo -e “${GREEN}证书文件检查通过${NC}”

# 生成随机 UUID 和密码

echo -e “${YELLOW}生成 UUID 和密码…${NC}”
UUID=$(cat /proc/sys/kernel/random/uuid)
PASSWORD=$(tr -dc ‘a-zA-Z0-9’ < /dev/urandom | head -c 16)

echo -e “${GREEN}UUID: $UUID${NC}”
echo -e “${GREEN}密码: $PASSWORD${NC}”

# 创建安装目录

echo -e “${YELLOW}创建安装目录…${NC}”
mkdir -p “$INSTALL_DIR”
mkdir -p “$CONFIG_DIR”

# 下载 shoes

echo -e “${YELLOW}下载 shoes v${SHOES_VERSION}…${NC}”
cd /tmp
wget -O shoes.tar.gz “$SHOES_URL”

# 解压并安装

echo -e “${YELLOW}解压并安装…${NC}”
tar -xzf shoes.tar.gz
mv shoes “$INSTALL_DIR/”
chmod +x “$INSTALL_DIR/shoes”
rm -f shoes.tar.gz

# 创建配置文件

echo -e “${YELLOW}创建配置文件…${NC}”
cat > “$CONFIG_DIR/config.yaml” <<EOF

- address: 0.0.0.0:443
  transport: quic
  quic_settings:
  cert: $CERT_DIR/cert.pem
  key: $CERT_DIR/key.pem
  protocol:
  type: tuic
  uuid: $UUID
  password: $PASSWORD
  rules:
  - allow-all-direct
    EOF

# 创建 systemd 服务

echo -e “${YELLOW}创建 systemd 服务…${NC}”
cat > “$SERVICE_FILE” <<EOF
[Unit]
Description=Shoes Proxy Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/shoes -c $CONFIG_DIR/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# 重载 systemd 并启动服务

echo -e “${YELLOW}启动 shoes 服务…${NC}”
systemctl daemon-reload
systemctl enable shoes
systemctl start shoes

# 等待服务启动

sleep 2

# 检查服务状态

if systemctl is-active –quiet shoes; then
echo -e “${GREEN}================================${NC}”
echo -e “${GREEN}Shoes 安装成功！${NC}”
echo -e “${GREEN}================================${NC}”
echo -e “${GREEN}服务状态: 运行中${NC}”
echo -e “${GREEN}监听端口: 443${NC}”
echo -e “${GREEN}协议: TUIC v5${NC}”
echo “”
echo -e “${YELLOW}配置信息:${NC}”
echo -e “UUID: ${GREEN}$UUID${NC}”
echo -e “密码: ${GREEN}$PASSWORD${NC}”
echo -e “证书: ${GREEN}$CERT_DIR/cert.pem${NC}”
echo -e “密钥: ${GREEN}$CERT_DIR/key.pem${NC}”
echo “”
echo -e “${YELLOW}配置文件位置:${NC}”
echo -e “$CONFIG_DIR/config.yaml”
echo “”
echo -e “${YELLOW}常用命令:${NC}”
echo -e “查看状态: ${GREEN}systemctl status shoes${NC}”
echo -e “停止服务: ${GREEN}systemctl stop shoes${NC}”
echo -e “启动服务: ${GREEN}systemctl start shoes${NC}”
echo -e “重启服务: ${GREEN}systemctl restart shoes${NC}”
echo -e “查看日志: ${GREEN}journalctl -u shoes -f${NC}”
echo “”
echo -e “${YELLOW}请保存好 UUID 和密码用于客户端连接！${NC}”
else
echo -e “${RED}服务启动失败，请检查日志:${NC}”
echo -e “${RED}journalctl -u shoes -xe${NC}”
exit 1
fi
