#!/usr/bin/env bash
set -euo pipefail
: "${REBOOT:=1}"

log(){ printf '>>> %s\n' "$*"; }

cur="$(uname -r)"
log "Running kernel : $cur"

img_keep=""
if dpkg -s "linux-image-${cur}" >/dev/null 2>&1; then
  img_keep="linux-image-${cur}"
elif dpkg -s "linux-image-unsigned-${cur}" >/dev/null 2>&1; then
  img_keep="linux-image-unsigned-${cur}"
fi
log "Keep image pkg : ${img_keep:-<none (provider kernel)>}"
echo

mapfile -t purge_pkgs < <(
  dpkg -l 2>/dev/null | awk '/^ii/{
    if ($2 ~ /^linux-image-/  ) print $2;
    if ($2 ~ /^linux-headers-/) print $2;
    if ($2 ~ /^linux-xanmod/  ) print $2;
    if ($2 ~ /^linux-kbuild-/ ) print $2;
  }' | sort -u
)

if [[ -n "$img_keep" ]]; then
  purge_pkgs=( $(printf '%s\n' "${purge_pkgs[@]}" | grep -v -x "$img_keep") )
fi

if dpkg -s "linux-headers-$cur" >/dev/null 2>&1; then
  printf '%s\n' "${purge_pkgs[@]}" | grep -qx "linux-headers-$cur" || purge_pkgs+=("linux-headers-$cur")
fi

if ((${#purge_pkgs[@]})); then
  log "Purging packages: ${purge_pkgs[*]}"
  apt-get purge -y "${purge_pkgs[@]}" || true
else
  log "No kernel/header packages to purge."
fi
echo

for f in /boot/vmlinuz-* /boot/initrd.img-*; do
  [[ -e "$f" ]] || continue
  ver="${f##*/}"; ver="${ver#*-}"
  if [[ "$ver" != "$cur" ]]; then
    log "Removing /boot/$(basename "$f")"
    rm -f "$f" || true
  fi
done

for dir in /lib/modules/*; do
  [[ -d "$dir" ]] || continue
  ver="${dir#/lib/modules/}"
  if [[ "$ver" != "$cur" ]]; then
    log "Removing /lib/modules/$ver"
    rm -rf "$dir" || true
  fi
done

for f in /var/lib/initramfs-tools/*; do
  [[ -e "$f" ]] || continue
  ver="${f#/var/lib/initramfs-tools/}"
  if [[ "$ver" != "$cur" ]]; then
    log "Removing initramfs-tools record for $ver"
    rm -f "$f" || true
  fi
done

for d in /usr/src/linux-headers-*; do
  [[ -d "$d" ]] || continue
  log "Removing ${d}"
  rm -rf "$d" || true
done
echo

if [[ -d "/lib/modules/$cur" ]]; then
  log "Rebuilding initramfs for $cur ..."
  update-initramfs -u -k "$cur" || true
else
  log "SKIP initramfs rebuild: /lib/modules/$cur 不存在（provider 内核）"
fi

if command -v update-grub >/dev/null 2>&1; then
  log "Updating GRUB ..."
  update-grub || true
elif command -v grub-mkconfig >/dev/null 2>&1; then
  grub-mkconfig -o /boot/grub/grub.cfg || true
fi

apt-get autoremove -y --purge || true
echo
log "Done. Kept only: ${img_keep:-<provider kernel>} (running $cur). Headers fully removed."

if [[ "$REBOOT" == "1" ]]; then
  echo "Rebooting in 5s..."
  sleep 5
  systemctl reboot || reboot
fi
