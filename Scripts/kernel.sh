#!/usr/bin/env bash
# kernel.sh — 纯 APT：仅保留“当前正在运行的内核”及其 headers（必重启）
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

main() {
  need_root; apt_lock_wait
  cur="$(uname -r)"
  echo ">>> Current kernel: $cur"

  # 识别当前正在运行的 image/headers 包名
  keep_image=""
  if dpkg -s "linux-image-$cur" >/dev/null 2>&1; then
    keep_image="linux-image-$cur"
  elif dpkg -s "linux-image-unsigned-$cur" >/dev/null 2>&1; then
    keep_image="linux-image-unsigned-$cur"
  fi
  keep_headers=""
  if dpkg -s "linux-headers-$cur" >/dev/null 2>&1; then
    keep_headers="linux-headers-$cur"
  fi

  # 仅抓“版本化”包（不碰 meta 包）
  mapfile -t all_ver_pkgs < <(
    dpkg -l 2>/dev/null | awk '/^ii/{print $2}' | grep -E \
      '^(linux-image(-unsigned)?-[0-9]|linux-headers-[0-9]|linux-(kbuild|tools|source)-[0-9])'
  )

  # 过滤掉当前 image / headers
  to_purge=()
  for p in "${all_ver_pkgs[@]}"; do
    [[ -n "$keep_image"   && "$p" == "$keep_image"   ]] && continue
    [[ -n "$keep_headers" && "$p" == "$keep_headers" ]] && continue
    to_purge+=("$p")
  done

  echo ">>> Keep image   : ${keep_image:-<none>}"
  echo ">>> Keep headers : ${keep_headers:-<none>}"
  echo ">>> Purge packages (${#to_purge[@]}):"
  ((${#to_purge[@]})) && printf '    %s\n' "${to_purge[@]}" || echo "    <none>"
  echo

  # 纯 APT 清理
  if ((${#to_purge[@]})); then
    apt-get -y purge "${to_purge[@]}" || true
  fi
  apt-get -y autoremove --purge || true
  apt-get -y autoclean || true
  apt-get -y clean || true

  # 重建当前 initramfs + 刷新 GRUB（非 GRUB 环境会静默跳过）
  update-initramfs -u -k "$cur" || true
  update-grub || true

  echo ">>> Done. Only current kernel kept: $cur"

  # —— 必重启 ——
  sync
  echo "Rebooting now..."
  sleep 1
  systemctl reboot || reboot
}
main "$@"
