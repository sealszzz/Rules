#!/usr/bin/env bash
# keep-current-kernel.sh — 纯 APT 清理；仅保留“当前正在运行的内核及其 headers（含 -common）”
# 固定流程：等待 APT 锁 → 计算并 purge 旧版 → autoremove/autoclean/clean
#         → update-initramfs(当前内核) → update-grub → 强制重启
# 适配：Debian 13（含 cloud 内核）/ XanMod（main/lts/edge）
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "请用 root 运行"; exit 1; }; }

apt_lock_wait() {
  local tries=30
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock           >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock      >/dev/null 2>&1 || \
        fuser /var/cache/apt/archives/lock >/dev/null 2>&1 ; do
    ((tries--)) || { echo "APT 锁长期占用，退出"; exit 1; }
    sleep 1
  done
}

pkg_installed(){ dpkg -s "$1" >/dev/null 2>&1; }

main() {
  need_root
  apt_lock_wait

  local cur keep_image="" keep_headers=()
  cur="$(uname -r)"
  echo ">>> Current kernel: $cur"

  # 保留当前 image（signed / unsigned 二选一）
  if pkg_installed "linux-image-$cur"; then
    keep_image="linux-image-$cur"
  elif pkg_installed "linux-image-unsigned-$cur"; then
    keep_image="linux-image-unsigned-$cur"
  fi

  # 保留 headers（含 -common）
  if pkg_installed "linux-headers-$cur"; then
    keep_headers+=("linux-headers-$cur")
  fi
  if pkg_installed "linux-headers-$cur-common"; then
    keep_headers+=("linux-headers-$cur-common")
  fi

  # 仅匹配“版本化”包（不碰 meta 包）
  mapfile -t versioned < <(
    dpkg -l 2>/dev/null | awk '/^ii/{print $2}' | grep -E \
      '^(linux-image(-unsigned)?-[0-9]|linux-headers-[0-9]|linux-(kbuild|tools|source)-[0-9])'
  )

  # 计算待清单
  local to_purge=()
  for p in "${versioned[@]}"; do
    [[ -n "$keep_image" && "$p" == "$keep_image" ]] && continue
    local skip=0
    for h in "${keep_headers[@]:-}"; do
      [[ "$p" == "$h" ]] && { skip=1; break; }
    done
    ((skip==1)) && continue
    to_purge+=("$p")
  done

  echo ">>> Keep image   : ${keep_image:-<none>}"
  echo ">>> Keep headers : ${keep_headers[*]:-<none>}"
  echo ">>> Purge packages (${#to_purge[@]}):"
  if ((${#to_purge[@]})); then
    printf '    %s\n' "${to_purge[@]}"
  else
    echo "    <none>"
  fi
  echo

  # 纯 APT 清理
  if ((${#to_purge[@]})); then
    apt-get -y purge "${to_purge[@]}" || true
  fi
  apt-get -y autoremove --purge || true
  apt-get -y autoclean || true
  apt-get -y clean || true

  # 重建当前 initramfs & 刷新 GRUB（非 GRUB 环境静默容错）
  update-initramfs -u -k "$cur" || true
  update-grub || true

  echo ">>> Done. Only current kernel kept: $cur"
  echo ">>> Rebooting now..."
  sync
  sleep 1
  systemctl reboot || reboot
}

main "$@"
