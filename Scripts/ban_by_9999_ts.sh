#!/usr/bin/env bash
set -euo pipefail

TARGET="/usr/local/sbin/ban_by_9999_ts.sh"

HTTP_LOG="${HTTP_LOG:-/var/log/nginx/http_9999_access.log}"
STREAM_LOG="${STREAM_LOG:-/var/log/nginx/stream_access.log}"

WINDOW_MIN="${WINDOW_MIN:-30}"
MIN_HITS="${MIN_HITS:-3}"
BAN_TIMEOUT="${BAN_TIMEOUT:-7d}"

NFT_FAMILY="${NFT_FAMILY:-inet}"
NFT_TABLE="${NFT_TABLE:-filter}"
NFT_SET="${NFT_SET:-blacklist4}"

TAIL_LINES_HTTP="${TAIL_LINES_HTTP:-200000}"
TAIL_LINES_STREAM="${TAIL_LINES_STREAM:-200000}"

SVC_NAME="${SVC_NAME:-ban-by-9999-ts}"
SVC_PATH="/etc/systemd/system/${SVC_NAME}.service"
TIMER_PATH="/etc/systemd/system/${SVC_NAME}.timer"

usage() {
  cat <<'USAGE'
Usage:
  ban_by_9999_ts.sh --install
  ban_by_9999_ts.sh --run
  ban_by_9999_ts.sh --uninstall

Env overrides:
  WINDOW_MIN MIN_HITS BAN_TIMEOUT
  TAIL_LINES_HTTP TAIL_LINES_STREAM
  HTTP_LOG STREAM_LOG
  NFT_FAMILY NFT_TABLE NFT_SET
USAGE
}

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "FATAL: need root" >&2
    exit 1
  fi
}

is_blacklisted() {
  local ip="$1"
  nft get element "$NFT_FAMILY" "$NFT_TABLE" "$NFT_SET" "{ $ip }" >/dev/null 2>&1
}

ts_to_epoch() {
  local ts="$1"
  local d="${ts/:/ }"
  date -d "$d" +%s 2>/dev/null || true
}

run_once() {
  [[ -r "$HTTP_LOG" ]] || exit 0
  [[ -r "$STREAM_LOG" ]] || exit 0

  local cutoff_epoch
  cutoff_epoch="$(date -d "-${WINDOW_MIN} min" +%s)"

  local tmp_times tmp_times2 tmp_out
  tmp_times="$(mktemp)"
  tmp_times2="$(mktemp)"
  tmp_out="$(mktemp)"

  tail -n "$TAIL_LINES_HTTP" "$HTTP_LOG" \
  | awk -v cutoff="$cutoff_epoch" '
    function to_epoch(ts,    cmd, e, a, b) {
      gsub(":", " ", ts)
      split(ts, a, " ")
      split(a[1], b, "/")
      cmd = "date -d \"" b[1] " " b[2] " " b[3] " " a[2] ":" a[3] ":" a[4] "\" +%s"
      cmd | getline e
      close(cmd)
      return e+0
    }

    {
      has_sni = match($0, /sni="([^"]*)"/, s)
      if (has_sni) {
        if (s[1] == "-" || s[1] == "") next
      }
    }

    match($0, /\[([0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2}) [+-][0-9]{4}\]/, t) {
      ts=t[1]
      if (to_epoch(ts) >= cutoff) print ts
    }
  ' | sort -u >"$tmp_times"

  if [[ ! -s "$tmp_times" ]]; then
    rm -f "$tmp_times" "$tmp_times2" "$tmp_out"
    exit 0
  fi

  while read -r ts; do
    [[ -z "$ts" ]] && continue
    e="$(ts_to_epoch "$ts")"
    [[ -z "$e" ]] && continue
    date -d "@$((e-1))" "+%d/%b/%Y:%H:%M:%S"
    date -d "@$e"        "+%d/%b/%Y:%H:%M:%S"
    date -d "@$((e+1))" "+%d/%b/%Y:%H:%M:%S"
  done <"$tmp_times" | sort -u >"$tmp_times2"

  mv -f "$tmp_times2" "$tmp_times"

  tail -n "$TAIL_LINES_STREAM" "$STREAM_LOG" \
  | awk '
    BEGIN {
      while ((getline line < ARGV[1]) > 0) times[line]=1
      close(ARGV[1])
      ARGV[1]=""
    }
    match($0, /\[([0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2}) [+-][0-9]{4}\]/, t) {
      ts=t[1]
      if (!(ts in times)) next
      ip=$1
      if (ip ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) cnt[ip]++
    }
    END { for (ip in cnt) print ip, cnt[ip] }
  ' "$tmp_times" /dev/stdin \
  | sort -k2,2nr >"$tmp_out"

  while read -r ip hits; do
    [[ -z "${ip:-}" ]] && continue
    [[ "${hits:-0}" -lt "$MIN_HITS" ]] && continue
    if is_blacklisted "$ip"; then
      continue
    fi
    nft add element "$NFT_FAMILY" "$NFT_TABLE" "$NFT_SET" "{ $ip timeout $BAN_TIMEOUT }" >/dev/null 2>&1 || true
  done <"$tmp_out"

  rm -f "$tmp_times" "$tmp_out"
}

install_units() {
  need_root

  local src
  src="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)"
  if [[ -n "${src:-}" && -r "$src" ]]; then
    install -m 0755 "$src" "$TARGET"
  else
    echo "FATAL: cannot locate readable script source to self-install. Please save the script to a file then run --install." >&2
    exit 1
  fi

  cat >"$SVC_PATH" <<EOF
[Unit]
Description=Ban IPs by correlating nginx 9999 access log with stream log
After=network.target

[Service]
Type=oneshot
ExecStart=${TARGET} --run
EOF

  cat >"$TIMER_PATH" <<EOF
[Unit]
Description=Run ${SVC_NAME} every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SVC_NAME}.timer"
  echo "OK: installed ${TARGET} and enabled ${SVC_NAME}.timer"
}

uninstall_units() {
  need_root
  systemctl disable --now "${SVC_NAME}.timer" >/dev/null 2>&1 || true
  rm -f "$SVC_PATH" "$TIMER_PATH"
  systemctl daemon-reload
  echo "OK: removed ${SVC_NAME}.service/.timer"
}

main() {
  case "${1:-}" in
    --run) run_once ;;
    --install) install_units ;;
    --uninstall) uninstall_units ;;
    -h|--help|"") usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
