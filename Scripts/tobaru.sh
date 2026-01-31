#!/usr/bin/env bash
set -euo pipefail

REPO="cfal/tobaru"
BIN_PATH="/usr/local/bin/tobaru"
CONF_DIR="/etc/tobaru"
CONF_PATH="${CONF_DIR}/sni_passthrough.yml"
SERVICE_PATH="/etc/systemd/system/tobaru.service"

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Please run as root"; exit 1; }; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "unsupported:$m" ;;
  esac
}

install_deps_debian() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends curl ca-certificates tar gzip unzip file >/dev/null
}

pick_asset_url_gnu_only() {
  local arch="$1"
  local api json urls picked

  api="https://api.github.com/repos/${REPO}/releases/latest"
  json="$(curl -fsSL "$api")"

  urls="$(printf '%s' "$json" \
    | grep -Eo '"browser_download_url":[ ]*"[^"]+"' \
    | sed -E 's/^"browser_download_url":[ ]*"//; s/"$//' \
    | sort -u)"

  if [[ "$arch" == "amd64" ]]; then
    picked="$(printf '%s\n' "$urls" \
      | grep -Ei 'linux' \
      | grep -Ei '(x86_64|amd64)' \
      | grep -Ei 'gnu' \
      | grep -Eiv 'musl' \
      | head -n1 || true)"
  else
    picked="$(printf '%s\n' "$urls" \
      | grep -Ei 'linux' \
      | grep -Ei '(aarch64|arm64)' \
      | grep -Ei 'gnu' \
      | grep -Eiv 'musl' \
      | head -n1 || true)"
  fi

  if [[ -z "$picked" ]]; then
    echo "ERROR: No GNU (non-musl) Linux asset found in latest release for arch=$arch."
    return 1
  fi

  echo "$picked"
}

download_and_install() {
  local url="$1"
  local tmpdir archive extracted_bin

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir:-}"' EXIT

  echo "Downloading: $url"
  archive="$tmpdir/asset"
  curl -fL --retry 3 --retry-delay 1 -o "$archive" "$url"

  mkdir -p "$tmpdir/out"

  if file "$archive" | grep -qi 'Zip archive'; then
    unzip -q "$archive" -d "$tmpdir/out"
  else
    tar -xf "$archive" -C "$tmpdir/out"
  fi

  extracted_bin="$(find "$tmpdir/out" -type f -name 'tobaru*' | head -n1 || true)"
  [[ -n "$extracted_bin" ]] || { echo "ERROR: tobaru binary not found in asset."; exit 1; }

  install -m 0755 "$extracted_bin" "$BIN_PATH"
  echo "Installed: $BIN_PATH"
}

write_config() {
  install -d -m 0755 "$CONF_DIR"

  cat >"$CONF_PATH" <<'YAML'
- address: 0.0.0.0:443
  transport: tcp
  targets:
    - location: 127.0.0.1:9001
      server_tls:
        mode: passthrough
        sni_hostnames: "example.com"

    - location: 127.0.0.1:9002
      server_tls:
        mode: passthrough
        sni_hostnames: "www.example.com"

    - location: 127.0.0.1:9003
      server_tls:
        mode: passthrough
        sni_hostnames: "global.example.com"

    - location: 127.0.0.1:9999
      server_tls:
        mode: passthrough
        sni_hostnames: any

    - location: 127.0.0.1:9009
      server_tls:
        mode: passthrough
        sni_hostnames: none
YAML

  echo "Wrote config: $CONF_PATH"
}

write_systemd() {
  cat >"$SERVICE_PATH" <<EOF
[Unit]
Description=tobaru TLS SNI passthrough router
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} ${CONF_PATH}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=262144
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now tobaru
  echo "Systemd service enabled and started: tobaru"
}

main() {
  need_root

  if ! cmd_exists curl || ! cmd_exists tar || ! cmd_exists file; then
    if cmd_exists apt-get; then
      install_deps_debian
    else
      echo "Missing deps (curl/tar/file). Please install them and re-run."
      exit 1
    fi
  fi

  arch="$(detect_arch)"
  [[ "$arch" != unsupported:* ]] || { echo "Unsupported arch: ${arch#unsupported:}"; exit 1; }

  url="$(pick_asset_url_gnu_only "$arch")"
  download_and_install "$url"
  write_config
  write_systemd

  echo
  echo "Done."
  echo "Binary : $BIN_PATH"
  echo "Config : $CONF_PATH"
  echo "Status : systemctl status tobaru --no-pager"
}

main "$@"
