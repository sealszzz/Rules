#!/usr/bin/env bash
# keep-current-kernel.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "请用 root 运行"; exit 1; }; }

apt_lock_wait() {
  command -v fuser >/dev/null 2>&1 || { echo "缺少 fuser，请先安装: apt-get install -y psmisc"; exit 1; }
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

  if pkg_installed "linux-image-$cur"; then
    keep_image="linux-image-$cur"
  elif pkg_installed "linux-image-unsigned-$cur"; then
    keep_image="linux-image-unsigned-$cur"
  fi

  # 关键安全阀：拿不到当前 image 包名就别清理（避免清光内核）
  if [ -z "$keep_image" ]; then
    echo "FATAL: cannot determine installed kernel image package for uname -r=$cur" >&2
    echo "Refuse to purge to avoid removing all kernels." >&2
    exit 1
  fi

  if pkg_installed "linux-headers-$cur"; then
    keep_headers+=("linux-headers-$cur")
  fi
  if pkg_installed "linux-headers-$cur-common"; then
    keep_headers+=("linux-headers-$cur-common")
  fi

  mapfile -t versioned < <(
    dpkg -l 2>/dev/null | awk '/^ii/{print $2}' | grep -E \
      '^(linux-image(-unsigned)?-[0-9]|linux-headers-[0-9]|linux-(kbuild|tools|source)-[0-9])'
  )

  local to_purge=()
  for p in "${versioned[@]}"; do
    [[ "$p" == "$keep_image" ]] && continue
    local skip=0
    for h in "${keep_headers[@]:-}"; do
      [[ "$p" == "$h" ]] && { skip=1; break; }
    done
    ((skip==1)) && continue
    to_purge+=("$p")
  done

  echo ">>> Keep image   : ${keep_image}"
  echo ">>> Keep headers : ${keep_headers[*]:-<none>}"
  echo ">>> Purge packages (${#to_purge[@]}):"
  if ((${#to_purge[@]})); then
    printf '    %s\n' "${to_purge[@]}"
  else
    echo "    <none>"
  fi
  echo

  if ((${#to_purge[@]})); then
    apt-get -y purge "${to_purge[@]}" || true
  fi
  apt-get -y autoremove --purge || true
  apt-get -y autoclean || true
  apt-get -y clean || true

  update-initramfs -u -k "$cur" || true
  update-grub || true

  echo ">>> Done. Only current kernel kept: $cur"
  echo ">>> Rebooting now..."
  sync
  sleep 1
  systemctl reboot || reboot
}

main "$@"
