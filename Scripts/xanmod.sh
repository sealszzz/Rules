#!/usr/bin/env bash
# bootstrap-xanmod.sh — 基础环境 + XanMod LTS x64v3，一次跑完自动重启
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

waitapt() {
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 1
  done
}

# 0) 先保证 fuser 存在（否则 waitapt 会直接崩）
apt-get update -q
apt-get install -y --no-install-recommends psmisc ca-certificates >/dev/null

# 1) 基础环境
waitapt; apt-get update -q
waitapt; apt-get -yq full-upgrade
waitapt; apt-get -yq install --no-install-recommends \
  ca-certificates gnupg openssl \
  curl wget git \
  python3 python3-venv \
  build-essential \
  iproute2 iputils-ping dnsutils \
  tar xz-utils zstd unzip zip \
  jq bc sed \
  rsync lsof \
  tmux htop \
  vim nano
waitapt; apt-get -yq clean

# 2) 配置 XanMod 源并安装 LTS x64v3
install -d -m 0755 /etc/apt/keyrings

# 用 curl -fsSL：失败就退出；避免写出半成品 keyring
curl -fsSL https://dl.xanmod.org/archive.key | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
chmod 0644 /etc/apt/keyrings/xanmod-archive-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] https://deb.xanmod.org trixie main' > /etc/apt/sources.list.d/xanmod-release.list

waitapt; apt-get update -q
waitapt; apt-get install -y linux-xanmod-lts-x64v3

sleep 3
reboot
