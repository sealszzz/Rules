#!/usr/bin/env bash
set -euo pipefail

# ================== 管理器元信息 ==================
SCRIPT_NAME="ssrust"
SCRIPT_VERSION="1.2.0"
REMOTE_SCRIPT_URL="${REMOTE_SCRIPT_URL:-https://raw.githubusercontent.com/sealszzz/Rules/refs/heads/master/Surge/install_netstack_official_interactive.sh}"

# 固定默认版本（以后升级改这里，或用 update 子命令指定）
SS_RUST_VER_DEFAULT="v1.20.0"
SHADOWTLS_VER_DEFAULT="v3.1.1"
SNELL_VER_DEFAULT="v5.0.0"

# SS 方法固定为 128 位（按你的要求）
SS_METHOD_DEFAULT="2022-blake3-aes-128-gcm"

# ================== 通用函数 ==================
need_root(){ [[ $EUID -eq 0 ]] || { echo "请用 root 运行：sudo $SCRIPT_NAME $*"; exit 1; }; }
arch_map(){
  local arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64) echo "amd64";;
    arm64) echo "aarch64";;
    *) echo "不支持架构: $arch" >&2; exit 1;;
  esac
}
rand_port(){ shuf -i 20000-60000 -n 1; }
rand_key(){ tr -dc 'A-Za-z0-9!@#$%^&*()_+=' </dev/urandom | head -c 20; echo; }
install_base(){
  apt-get update -y
  apt-get install -y curl wget unzip xz-utils jq ufw nftables lsof ca-certificates
}

say(){ printf "\033[1;32m%s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
err(){ printf "\033[1;31m%s\033[0m\n" "$*"; }

# ================== 自更新 ==================
self_update(){
  need_root
  say "[Self-Update] 从远程拉取脚本：$REMOTE_SCRIPT_URL"
  tmp=$(mktemp)
  if ! curl -fsSL "$REMOTE_SCRIPT_URL" -o "$tmp"; then
    err "下载失败：$REMOTE_SCRIPT_URL"
    exit 1
  fi
  remote_ver=$(grep -E '^SCRIPT_VERSION=' "$tmp" | head -n1 | cut -d'"' -f2 || true)
  if [[ -n "$remote_ver" && "$remote_ver" != "$SCRIPT_VERSION" ]]; then
    say "发现新版本：$SCRIPT_VERSION -> $remote_ver"
  else
    say "脚本已是最新（或远端未提供版本号）。"
  fi
  install -m 0755 "$tmp" "/usr/local/bin/$SCRIPT_NAME"
  rm -f "$tmp"
  say "已更新为最新脚本。现在执行：$SCRIPT_NAME $*"
}

maybe_self_update(){
  if [[ "${AUTO_UPDATE:-1}" == "1" ]]; then
    warn "检测是否需要更新脚本（当前版本：$SCRIPT_VERSION）..."
    tmp=$(mktemp)
    if curl -fsSL "$REMOTE_SCRIPT_URL" -o "$tmp"; then
      remote_ver=$(grep -E '^SCRIPT_VERSION=' "$tmp" | head -n1 | cut -d'"' -f2 || true)
      if [[ -n "$remote_ver" && "$remote_ver" != "$SCRIPT_VERSION" ]]; then
        read -rp "检测到新版本 $remote_ver，是否更新？[Y/n]: " a; a=${a:-Y}
        if [[ "$a" =~ ^[Yy]$ ]]; then
          install -m 0755 "$tmp" "/usr/local/bin/$SCRIPT_NAME"
          rm -f "$tmp"
          exec "$SCRIPT_NAME" "$@"   # 立即用新脚本重启
        fi
      fi
    fi
    rm -f "$tmp" || true
  fi
}

# ================== 防火墙 ==================
open_ports(){
  local ports=("$@")
  if command -v ufw >/dev/null 2>&1; then
    ufw allow OpenSSH >/dev/null 2>&1 || true
    for p in "${ports[@]}"; do
      ufw allow ${p}/tcp >/dev/null 2>&1 || true
      ufw allow ${p}/udp >/dev/null 2>&1 || true
    done
    ufw status | grep -qi "Status: active" || yes | ufw enable
    ufw status || true
  else
    nft list tables | grep -q "table inet filter" || nft add table inet filter
    nft list chain inet filter input >/dev/null 2>&1 || nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }'
    for p in "${ports[@]}"; do
      nft add rule inet filter input tcp dport ${p} accept || true
      nft add rule inet filter input udp dport ${p} accept || true
    done
  fi
}

# ================== 安装/更新各组件 ==================
install_ss(){
  local ver="${1:-$SS_RUST_VER_DEFAULT}" port="$2" pwd="$3"
  say "[SS2022] 安装 shadowsocks-rust ${ver} ..."
  local chip="$(arch_map)"; local asset="x86_64"; [[ "$chip" == "aarch64" ]] && asset="aarch64"
  local base="shadowsocks-${ver}-${asset}-unknown-linux-gnu"
  tmp=$(mktemp -d); pushd "$tmp" >/dev/null
  curl -fsSL "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ver}/${base}.tar.xz" -o ss.tar.xz
  tar -xJf ss.tar.xz
  install -m 0755 ssserver /usr/local/bin/ssserver
  mkdir -p /etc/ss-rust
  cat >/etc/ss-rust/config.json <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${port},
  "method": "${SS_METHOD_DEFAULT}",
  "password": "${pwd}",
  "mode": "tcp_and_udp"
}
EOF
  cat >/etc/systemd/system/ss-rust.service <<'EOF'
[Unit]
Description=Shadowsocks-Rust (SS2022)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/ssserver -c /etc/ss-rust/config.json
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ss-rust
  popd >/dev/null; rm -rf "$tmp"
}

install_snell(){
  local ver="${1:-$SNELL_VER_DEFAULT}" port="$2" psk="$3" obfs="$4"
  say "[Snell] 安装 Snell ${ver} ..."
  local chip="$(arch_map)"; local arch_name="linux-${chip}"
  tmp=$(mktemp -d); pushd "$tmp" >/dev/null
  curl -fsSL "https://dl.nssurge.com/snell/snell-server-${ver}-${arch_name}.zip" -o snell.zip
  unzip -q snell.zip
  install -m 0755 snell-server /usr/local/bin/snell-server
  mkdir -p /etc/snell
  cat >/etc/snell/snell-server.conf <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = true
udp = true
obfs = ${obfs}
EOF
  cat >/etc/systemd/system/snell.service <<'EOF'
[Unit]
Description=Snell Proxy
After=network-online.target
[Service]
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now snell
  popd >/dev/null; rm -rf "$tmp"
}

install_shadowtls(){
  local ver="${1:-$SHADOWTLS_VER_DEFAULT}" port="$2" pwd="$3" backend="$4" sni="$5"
  say "[ShadowTLS] 安装 v3 (${ver}) ..."
  local chip="$(arch_map)"; local asset="x86_64"; [[ "$chip" == "aarch64" ]] && asset="aarch64"
  curl -fsSL "https://github.com/ihciah/shadow-tls/releases/download/${ver}/shadow-tls-linux-${asset}" -o /usr/local/bin/shadow-tls
  chmod +x /usr/local/bin/shadow-tls
  cat >/etc/systemd/system/shadow-tls.service <<EOF
[Unit]
Description=ShadowTLS v3
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/shadow-tls --v3 -p ${port} -k ${pwd} --backend ${backend} --tls ${sni} --fastopen
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now shadow-tls
}

# ================== 辅助：读取现有配置 ==================
read_ss(){
  [[ -f /etc/ss-rust/config.json ]] || return 1
  jq -r '"SS_PORT=\(.server_port)\nSS_PASSWORD=\(.password)\nSS_METHOD=\(.method)"' /etc/ss-rust/config.json
}
read_snell(){
  [[ -f /etc/snell/snell-server.conf ]] || return 1
  awk -F= '
    /^listen/{gsub(/[ \t]/,""); split($2,a,":"); print "SNELL_PORT="a[length(a)]}
    /^psk/{gsub(/[ \t]/,""); print "SNELL_PSK="$2}
    /^obfs/{gsub(/[ \t]/,""); print "SNELL_OBFS="$2}
  ' /etc/snell/snell-server.conf
}
read_stls(){
  [[ -f /etc/systemd/system/shadow-tls.service ]] || return 1
  grep -E '^ExecStart=' /etc/systemd/system/shadow-tls.service | \
  sed -E 's/.* -p[[:space:]]+([0-9]+).* -k[[:space:]]+([^[:space:]]+).* --backend[[:space:]]+([^[:space:]]+).* --tls[[:space:]]+([^[:space:]]+).*/STLS_PORT=\1\nSTLS_PASSWORD=\2\nSTLS_BACKEND=\3\nSTLS_SNI=\4/'
}

# ================== 交互输入（随机或自填） ==================
ask_rand_or_input(){
  local label="$1" must="$2" default="${3:-}"
  local choice val
  while true; do
    read -rp "$label 随机生成吗？[Y/n]: " choice; choice=${choice:-Y}
    if [[ "$choice" =~ ^[Yy]$ ]]; then
      echo "__RANDOM__"; return 0
    else
      read -rp "请输入 $label${default:+（默认 $default）}: " val
      val=${val:-$default}
      [[ -n "$val" || "$must" != "1" ]] && { echo "$val"; return 0; }
      err "不能为空。"
    fi
  done
}

# ================== 安装流程（交互，只问端口/密钥/SNI） ==================
cmd_install(){
  need_root; install_base

  local ans SS_PORT SS_PWD SNELL_PORT SNELL_PSK SNELL_OBFS STLS_PORT STLS_PWD STLS_BACKEND STLS_SNI

  ans=$(ask_rand_or_input "SS2022 端口" 1); [[ "$ans" == "__RANDOM__" ]] && SS_PORT=$(rand_port) || SS_PORT="$ans"
  ans=$(ask_rand_or_input "SS2022 密码" 1); [[ "$ans" == "__RANDOM__" ]] && SS_PWD=$(rand_key) || SS_PWD="$ans"

  ans=$(ask_rand_or_input "Snell 端口" 1); [[ "$ans" == "__RANDOM__" ]] && SNELL_PORT=$(rand_port) || SNELL_PORT="$ans"
  ans=$(ask_rand_or_input "Snell PSK" 1); [[ "$ans" == "__RANDOM__" ]] && SNELL_PSK=$(rand_key) || SNELL_PSK="$ans"
  read -rp "Snell obfs [none/tls/http2]（默认 none）: " SNELL_OBFS; SNELL_OBFS=${SNELL_OBFS:-none}

  ans=$(ask_rand_or_input "ShadowTLS 端口" 1); [[ "$ans" == "__RANDOM__" ]] && STLS_PORT=$(rand_port) || STLS_PORT="$ans"
  ans=$(ask_rand_or_input "ShadowTLS 密码" 1); [[ "$ans" == "__RANDOM__" ]] && STLS_PWD=$(rand_key) || STLS_PWD="$ans"
  read -rp "ShadowTLS 后端（默认 127.0.0.1:${SS_PORT}）: " STLS_BACKEND; STLS_BACKEND=${STLS_BACKEND:-"127.0.0.1:${SS_PORT}"}
  read -rp "ShadowTLS SNI（例如 gateway.icloud.com）: " STLS_SNI; [[ -z "$STLS_SNI" ]] && { err "SNI 不能为空"; exit 1; }

  open_ports "$SS_PORT" "$SNELL_PORT" "$STLS_PORT"

  install_ss "$SS_RUST_VER_DEFAULT" "$SS_PORT" "$SS_PWD"
  install_snell "$SNELL_VER_DEFAULT" "$SNELL_PORT" "$SNELL_PSK" "$SNELL_OBFS"
  install_shadowtls "$SHADOWTLS_VER_DEFAULT" "$STLS_PORT" "$STLS_PWD" "$STLS_BACKEND" "$STLS_SNI"

  say "===== 安装完成 ====="
  echo "SS2022: 端口=$SS_PORT 方法=$SS_METHOD_DEFAULT 密码=$SS_PWD"
  echo "Snell v5: 端口=$SNELL_PORT PSK=$SNELL_PSK obfs=$SNELL_OBFS"
  echo "ShadowTLS v3: 端口=$STLS_PORT 密码=$STLS_PWD 后端=$STLS_BACKEND SNI=$STLS_SNI"
  say "可执行：$SCRIPT_NAME surge   # 自动生成 Surge 的 [Proxy] 配置段"
}

# ================== 更新组件（可指定版本；支持 latest for GitHub 项目） ==================
# 用法示例：
#   ssrust update --ss=latest --snell=v5.0.0 --stls=latest
cmd_update(){
  need_root; install_base
  local ss_ver="$SS_RUST_VER_DEFAULT" snell_ver="$SNELL_VER_DEFAULT" stls_ver="$SHADOWTLS_VER_DEFAULT"

  # 解析参数
  for a in "$@"; do
    case "$a" in
      --ss=*) ss_ver="${a#--ss=}";;
      --snell=*) snell_ver="${a#--snell=}";;
      --stls=*) stls_ver="${a#--stls=}";;
    esac
  done

  # latest: 查询 GitHub 最新 tag（仅 SS/STLS 支持；Snell 无官方 API，只能手动指定）
  if [[ "$ss_ver" == "latest" ]]; then
    ss_ver=$(curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r .tag_name)
  fi
  if [[ "$stls_ver" == "latest" ]]; then
    stls_ver=$(curl -fsSL https://api.github.com/repos/ihciah/shadow-tls/releases/latest | jq -r .tag_name)
  fi

  # 读取现有端口/密码/SNI
  eval "$(read_ss || true)"; eval "$(read_snell || true)"; eval "$(read_stls || true)"

  [[ -z "${SS_PORT:-}" || -z "${SS_PASSWORD:-}" ]] && { err "未检测到已安装的 SS2022。请先执行：$SCRIPT_NAME install"; exit 1; }
  [[ -z "${SNELL_PORT:-}" || -z "${SNELL_PSK:-}" ]] && warn "未检测到 Snell 配置，将跳过 Snell 更新。"
  [[ -z "${STLS_PORT:-}" || -z "${STLS_PASSWORD:-}" || -z "${STLS_BACKEND:-}" || -z "${STLS_SNI:-}" ]] && warn "未检测到 ShadowTLS 配置，将跳过 ShadowTLS 更新。"

  # 停服务（不会清配置）
  systemctl stop ss-rust 2>/dev/null || true
  systemctl stop snell 2>/dev/null || true
  systemctl stop shadow-tls 2>/dev/null || true

  # 逐个更新并沿用原配置
  install_ss "$ss_ver" "$SS_PORT" "$SS_PASSWORD"
  [[ -n "${SNELL_PORT:-}" ]] && install_snell "$snell_ver" "$SNELL_PORT" "$SNELL_PSK" "${SNELL_OBFS:-none}" || true
  [[ -n "${STLS_PORT:-}" ]] && install_shadowtls "$stls_ver" "$STLS_PORT" "$STLS_PASSWORD" "$STLS_BACKEND" "$STLS_SNI" || true

  say "组件更新完成。"
}

# ================== 状态/导出配置/生成 Surge ==================
cmd_status(){
  systemctl --no-pager -l status ss-rust snell shadow-tls || true
  ss -lntup | grep -E 'ssserver|snell|shadow-tls' || true
}
cmd_config(){
  read_ss || true; read_snell || true; read_stls || true
}
cmd_surge(){
  local ip
  ip=$(curl -fsSL https://ipinfo.io/ip || echo "<YOUR_VPS_IP>")
  eval "$(read_ss || true)"; eval "$(read_snell || true)"; eval "$(read_stls || true)"
  [[ -z "${SS_PORT:-}" || -z "${SS_PASSWORD:-}" ]] && { err "未找到 SS 配置。"; return 1; }

  cat <<EOF
[Proxy]
# 1) SS2022 + ShadowTLS（如已装 ShadowTLS）
My-SS2022-ShadowTLS = ss, ${ip}, ${STLS_PORT:-<STLS_PORT>}, encrypt-method=${SS_METHOD_DEFAULT}, password=${SS_PASSWORD:-<SS_PASSWORD>}, udp-relay=true, obfs=shadow-tls, obfs-host=${STLS_SNI:-<SNI>}, obfs-password=${STLS_PASSWORD:-<STLS_PASSWORD>}

# 2) Snell v5 + ShadowTLS（如已装）
My-Snell-ShadowTLS = snell, ${ip}, ${STLS_PORT:-<STLS_PORT_FOR_SNELL>}, psk=${SNELL_PSK:-<SNELL_PSK>}, version=5, udp-relay=true, obfs=shadow-tls, obfs-host=${STLS_SNI:-<SNI>}, obfs-password=${STLS_PASSWORD:-<STLS_PASSWORD>}

# 3) 备用：直连 SS2022
My-SS2022-Direct = ss, ${ip}, ${SS_PORT}, encrypt-method=${SS_METHOD_DEFAULT}, password=${SS_PASSWORD}, udp-relay=true
EOF
}

# ================== 卸载（保留/删除配置交互） ==================
cmd_uninstall(){
  need_root
  read -rp "是否删除二进制（ssserver/snell-server/shadow-tls）？[y/N]: " d1; d1=${d1:-N}
  read -rp "是否删除配置（/etc/ss-rust /etc/snell）？[y/N]: " d2; d2=${d2:-N}
  systemctl stop ss-rust snell shadow-tls 2>/dev/null || true
  systemctl disable ss-rust snell shadow-tls 2>/dev/null || true
  rm -f /etc/systemd/system/ss-rust.service /etc/systemd/system/snell.service /etc/systemd/system/shadow-tls.service
  systemctl daemon-reload
  [[ "$d1" =~ ^[Yy]$ ]] && rm -f /usr/local/bin/ssserver /usr/local/bin/snell-server /usr/local/bin/shadow-tls
  [[ "$d2" =~ ^[Yy]$ ]] && rm -rf /etc/ss-rust /etc/snell
  say "已卸载服务。"
}

# ================== 帮助 ==================
usage(){
  cat <<'EOF'
用法：ssrust [子命令] [选项]
子命令：
  install           交互安装（只问端口/密钥/SNI，版本固定为脚本内默认）
  update [opts]     更新二进制，沿用原端口/密钥/SNI
                    选项：--ss=<tag|latest>  --snell=<tag>  --stls=<tag|latest>
  status            查看服务状态与监听端口
  config            输出当前配置要点（端口/密钥/方法/SNI/后端）
  surge             生成 Surge 的 [Proxy] 配置段（自动带上你的外网IP）
  uninstall         卸载（可选是否删除二进制与配置）
  --self-update     自更新脚本（从远程 REMOTE_SCRIPT_URL 覆盖 /usr/local/bin/ssrust）
  -h, --help        显示帮助

环境变量：
  REMOTE_SCRIPT_URL   自更新地址（默认指向你的 GitHub Raw）
  AUTO_UPDATE=1       运行时检查是否有新版本，提示更新（默认 1）

示例：
  ssrust install
  ssrust update --ss=latest --stls=latest --snell=v5.0.0
  ssrust status
  ssrust surge > surge_proxies.conf
  ssrust --self-update
EOF
}

# ================== 入口 ==================
main(){
  cmd="${1:-}"; shift || true
  case "$cmd" in
    install) maybe_self_update "$cmd" "$@"; cmd_install "$@";;
    update)  maybe_self_update "$cmd" "$@"; cmd_update "$@";;
    status)  cmd_status;;
    config)  cmd_config;;
    surge)   cmd_surge;;
    uninstall) cmd_uninstall;;
    --self-update) self_update "$@";;
    -h|--help|"") usage;;
    *) err "未知命令：$cmd"; usage; exit 1;;
  esac
}
main "$@"
