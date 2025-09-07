#!/usr/bin/env bash
set -euo pipefail

# ================== 默认官方版本（仅作默认，可在交互中改） ==================
SS_RUST_VER_DEFAULT="v1.20.0"
SHADOWTLS_VER_DEFAULT="v3.1.1"
SNELL_VER_DEFAULT="v5.0.0"

# ================== 工具函数 ==================
need_root() { [[ $EUID -eq 0 ]] || { echo "请用 root 运行：sudo bash $0"; exit 1; }; }
on_debian12() { . /etc/os-release; [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "12" ]]; }
rand_port() { shuf -i 20000-60000 -n 1; }
rand_key()  { tr -dc 'A-Za-z0-9!@#$%^&*()_+=' </dev/urandom | head -c 20; echo; }
ask_rand_or_input() {  # $1 提示文案  $2 默认值(可空)
  local choice val
  while true; do
    read -rp "$1 随机生成吗？[Y/n]: " choice
    choice=${choice:-Y}
    if [[ "$choice" =~ ^[Yy]$ ]]; then
      echo "__RANDOM__"
      return 0
    elif [[ "$choice" =~ ^[Nn]$ ]]; then
      read -rp "请输入值${2:+（默认 $2）}: " val
      val=${val:-$2}
      [[ -n "$val" ]] && { echo "$val"; return 0; }
      echo "输入不能为空。" >&2
    else
      echo "请输入 Y 或 n。" >&2
    fi
  done
}
arch_map() {
  local arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64)   echo "amd64";;
    arm64)   echo "aarch64";;
    *) echo "不支持的架构: $arch" >&2; exit 1;;
  esac
}
install_base() {
  apt-get update
  apt-get install -y curl wget jq ca-certificates tar xz-utils unzip lsof ufw nftables
}

# ================== 防火墙（TCP+UDP） ==================
open_ports() {
  local ports=("$@")
  if command -v ufw >/dev/null 2>&1; then
    ufw allow OpenSSH || true
    for p in "${ports[@]}"; do ufw allow ${p}/tcp || true; ufw allow ${p}/udp || true; done
    ufw status | grep -qi "Status: active" || yes | ufw enable
    ufw status || true
  else
    nft list tables | grep -q "table inet filter" || nft add table inet filter
    nft list chain inet filter input >/dev/null 2>&1 || nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }'
    for p in "${ports[@]}"; do
      nft add rule inet filter input tcp dport ${p} accept || true
      nft add rule inet filter input udp dport ${p} accept || true
    done
    echo "提示：如需持久化 nft 规则，请写入 /etc/nftables.conf，并执行 systemctl enable --now nftables"
  fi
}

# ================== 安装 SS2022（shadowsocks-rust 官方二进制） ==================
install_ss_rust() {
  local ver="$1" ss_port="$2" ss_pwd="$3" method="$4"
  echo "[SS2022] 安装 shadowsocks-rust ${ver} ..."
  local chip="$(arch_map)"
  local asset="x86_64"; [[ "$chip" == "aarch64" ]] && asset="aarch64"
  local base="shadowsocks-${ver}-${asset}-unknown-linux-gnu"

  tmp=$(mktemp -d); pushd "$tmp" >/dev/null
  url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ver}/${base}.tar.xz"
  curl -fSL "$url" -o ss.tar.xz
  tar -xJf ss.tar.xz
  install -m 0755 ssserver /usr/local/bin/ssserver

  mkdir -p /etc/ss-rust
  cat >/etc/ss-rust/config.json <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${ss_port},
  "method": "${method}",
  "password": "${ss_pwd}",
  "mode": "tcp_and_udp",
  "fast_open": true,
  "ipv6_first": false
}
EOF

  cat >/etc/systemd/system/ss-rust.service <<'EOF'
[Unit]
Description=Shadowsocks-Rust Server (SS2022)
After=network-online.target
Wants=network-online.target

[Service]
User=root
ExecStart=/usr/local/bin/ssserver -c /etc/ss-rust/config.json
Restart=on-failure
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ss-rust
  systemctl status ss-rust --no-pager -l || true
  popd >/dev/null; rm -rf "$tmp"
}

# ================== 安装 Snell v5（官方 dl.nssurge.com） ==================
install_snell_v5() {
  local ver="$1" snell_port="$2" snell_psk="$3" snell_obfs="$4"
  echo "[Snell] 安装 Snell ${ver} ..."
  local chip="$(arch_map)"
  local dl_arch=""
  case "$chip" in
    amd64)   dl_arch="linux-amd64";;
    aarch64) dl_arch="linux-aarch64";;
  esac

  tmp=$(mktemp -d); pushd "$tmp" >/dev/null
  url="https://dl.nssurge.com/snell/snell-server-${ver}-${dl_arch}.zip"
  curl -fSL "$url" -o snell.zip
  unzip -q snell.zip
  install -m 0755 snell-server /usr/local/bin/snell-server
  popd >/dev/null; rm -rf "$tmp"

  mkdir -p /etc/snell
  cat >/etc/snell/snell-server.conf <<EOF
[snell-server]
listen = 0.0.0.0:${snell_port}
psk = ${snell_psk}
ipv6 = true
udp = true
obfs = ${snell_obfs}
EOF

  cat >/etc/systemd/system/snell.service <<'EOF'
[Unit]
Description=Snell Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now snell
  systemctl status snell --no-pager -l || true
}

# ================== 安装 ShadowTLS v3（官方二进制，含 SNI 输入） ==================
install_shadowtls_v3() {
  local ver="$1" stls_port="$2" stls_pwd="$3" backend="$4" sni="$5"
  echo "[ShadowTLS] 安装 shadow-tls ${ver} (v3 模式) ..."
  local chip="$(arch_map)"
  local asset="x86_64"; [[ "$chip" == "aarch64" ]] && asset="aarch64"

  tmp=$(mktemp -d); pushd "$tmp" >/dev/null
  url="https://github.com/ihciah/shadow-tls/releases/download/${ver}/shadow-tls-linux-${asset}"
  curl -fSL "$url" -o /usr/local/bin/shadow-tls
  chmod +x /usr/local/bin/shadow-tls
  popd >/dev/null; rm -rf "$tmp"

  # systemd：显式 --v3，并使用用户输入的 SNI
  cat >/etc/systemd/system/shadow-tls.service <<EOF
[Unit]
Description=Shadow-TLS v3 Server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/shadow-tls --v3 -p ${stls_port} -k ${stls_pwd} --backend ${backend} --tls ${sni} --fastopen
Restart=always
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now shadow-tls
  systemctl status shadow-tls --no-pager -l || true
}

# ================== 主流程（逐项询问“随机还是自定义”） ==================
main() {
  need_root
  on_debian12 || echo "警告：当前不是 Debian 12（继续可能失败）"
  install_base

  echo "== SS2022 (shadowsocks-rust) =="
  local v ans
  ans="$(ask_rand_or_input 'SS2022 端口' '')"
  [[ "$ans" == "__RANDOM__" ]] && SS_PORT=$(rand_port) || SS_PORT="$ans"
  ans="$(ask_rand_or_input 'SS2022 密码' '')"
  [[ "$ans" == "__RANDOM__" ]] && SS_PWD=$(rand_key) || SS_PWD="$ans"
  read -rp "SS2022 加密（默认 2022-blake3-aes-256-gcm）: " SS_METHOD || true
  SS_METHOD=${SS_METHOD:-"2022-blake3-aes-256-gcm"}
  read -rp "SS-Rust 版本 tag（默认 ${SS_RUST_VER_DEFAULT}）: " v || true
  SS_VER=${v:-$SS_RUST_VER_DEFAULT}

  echo "== Snell v5 =="
  ans="$(ask_rand_or_input 'Snell 端口' '')"
  [[ "$ans" == "__RANDOM__" ]] && SNELL_PORT=$(rand_port) || SNELL_PORT="$ans"
  ans="$(ask_rand_or_input 'Snell PSK' '')"
  [[ "$ans" == "__RANDOM__" ]] && SNELL_PSK=$(rand_key) || SNELL_PSK="$ans"
  read -rp "Snell obfs [none/tls/http2]（默认 none）: " SNELL_OBFS || true
  SNELL_OBFS=${SNELL_OBFS:-none}
  read -rp "Snell 版本 tag（默认 ${SNELL_VER_DEFAULT}）: " v || true
  SNELL_VER=${v:-$SNELL_VER_DEFAULT}

  echo "== ShadowTLS v3 =="
  ans="$(ask_rand_or_input 'ShadowTLS 端口' '')"
  [[ "$ans" == "__RANDOM__" ]] && STLS_PORT=$(rand_port) || STLS_PORT="$ans"
  ans="$(ask_rand_or_input 'ShadowTLS 密码' '')"
  [[ "$ans" == "__RANDOM__" ]] && STLS_PWD=$(rand_key) || STLS_PWD="$ans"
  read -rp "ShadowTLS 版本 tag（默认 ${SHADOWTLS_VER_DEFAULT}）: " v || true
  STLS_VER=${v:-$SHADOWTLS_VER_DEFAULT}
  # 后端默认回源到 SS2022
  read -rp "ShadowTLS 后端（默认 127.0.0.1:${SS_PORT} ）: " STLS_BACKEND || true
  STLS_BACKEND=${STLS_BACKEND:-"127.0.0.1:${SS_PORT}"}
  # SNI 必须允许自定义
  read -rp "ShadowTLS SNI（如 www.microsoft.com / www.google.com）: " STLS_SNI
  [[ -z "$STLS_SNI" ]] && { echo "SNI 不能为空。"; exit 1; }

  echo "== 放行端口（TCP+UDP） =="
  open_ports "${SS_PORT}" "${SNELL_PORT}" "${STLS_PORT}"

  echo "== 安装 SS2022（shadowsocks-rust） =="
  install_ss_rust "$SS_VER" "$SS_PORT" "$SS_PWD" "$SS_METHOD"

  echo "== 安装 Snell v5（官方 dl.nssurge.com） =="
  install_snell_v5 "$SNELL_VER" "$SNELL_PORT" "$SNELL_PSK" "$SNELL_OBFS"

  echo "== 安装 ShadowTLS v3（官方 release） =="
  install_shadowtls_v3 "$STLS_VER" "$STLS_PORT" "$STLS_PWD" "$STLS_BACKEND" "$STLS_SNI"

  echo
  echo "===== 完成 ====="
  echo "SS2022: 端口=${SS_PORT}  密码=${SS_PWD}  方法=${SS_METHOD}  版本=${SS_VER}"
  echo "Snell v5: 端口=${SNELL_PORT}  PSK=${SNELL_PSK}  obfs=${SNELL_OBFS}  版本=${SNELL_VER}"
  echo "ShadowTLS v3: 端口=${STLS_PORT}  密码=${STLS_PWD}  回源=${STLS_BACKEND}  SNI=${STLS_SNI}  版本=${STLS_VER}"
  echo
  echo "验证监听: ss -lntup | grep -E ':(${SS_PORT}|${SNELL_PORT}|${STLS_PORT})\\b' || true"
  echo "外部 UDP 扫描: nmap -sU -p ${SS_PORT},${SNELL_PORT},${STLS_PORT} <VPS_IP>"
}

main "$@"
