#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root"
}

wait_for_apt() {
  local locks=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
  )
  while :; do
    local busy=0
    for f in "${locks[@]}"; do
      if fuser "$f" >/dev/null 2>&1; then
        busy=1
        break
      fi
    done
    (( busy == 0 )) && break
    warn "Waiting for apt/dpkg lock"
    sleep 2
  done
}

pkg_installed() {
  dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

main() {
  need_root
  wait_for_apt

  dpkg --configure -a || true
  apt-get -fy install || true

  local cur installed pkg
  local -a keep purge

  cur="$(uname -r)"
  [[ -n "$cur" ]] || die "Failed to get current kernel version"

  installed="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort -u)"
  [[ -n "$installed" ]] || die "Failed to read installed package list"

  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    case "$pkg" in
      linux-image-*|linux-headers-*|linux-modules-*|linux-modules-extra-*|linux-tools-*|linux-kbuild-*|linux-source-*|linux-compiler-* )
        if [[ "$pkg" == *"$cur"* ]]; then
          keep+=("$pkg")
        else
          purge+=("$pkg")
        fi
        ;;
    esac
  done <<< "$installed"

  ((${#keep[@]} > 0)) || die "No packages found for the running kernel: $cur"

  mapfile -t keep < <(printf '%s\n' "${keep[@]}" | sort -u)
  mapfile -t purge < <(printf '%s\n' "${purge[@]:-}" | sort -u)

  log "Running kernel: $cur"
  log "Packages to keep:"
  printf '  %s\n' "${keep[@]}"

  if ((${#purge[@]} > 0)); then
    log "Packages to purge:"
    printf '  %s\n' "${purge[@]}"
    apt-get purge -y "${purge[@]}"
  else
    log "No old kernel packages to purge"
  fi

  apt-get autoremove -y --purge
  apt-get clean

  if [[ -e "/boot/initrd.img-$cur" ]] || pkg_installed initramfs-tools; then
    update-initramfs -u -k "$cur"
  fi

  if command -v update-grub >/dev/null 2>&1; then
    update-grub
  fi

  sleep 5
  systemctl reboot || reboot
}

main "$@"
