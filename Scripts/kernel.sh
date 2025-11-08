#!/usr/bin/env bash
# keep-current-kernel.sh (SAFE & EFFECTIVE)
# 保留当前正在运行的内核；删除其它所有 image/header/modules/initramfs。
# 绝不删除 /lib/modules/$cur

set -euo pipefail
: "${REBOOT:=1}"

log(){ printf '>>> %s\n' "$*"; }

cur="$(uname -r)"    # 例：6.12.57-x64v3-xanmod1
log "Running kernel : $cur"

###############################################################################
# 1) 找到当前内核 image 包（若没有，则表示 provider 内核，不删 image 包）
###############################################################################
img_keep=""
if dpkg -s "linux-image-${cur}" >/dev/null 2>&1; then
  img_keep="linux-image-${cur}"
elif dpkg -s "linux-image-unsigned-${cur}" >/dev/null 2>&1; then
  img_keep="linux-image-unsigned-${cur}"
fi

log "Keep image pkg : ${img_keep:-<none (provider kernel)>}"
echo

###############################################################################
# 2) 删除所有旧的 kernel image / headers（严格排除当前版本）
###############################################################################
mapfile -t purge_pkgs < <(
  dpkg -l 2>/dev/null | awk '/^ii/{
    if ($2 ~ /^linux-image-/   ) print $2;
    if ($2 ~ /^linux-headers-/ ) print $2;
    if ($2 ~ /^linux-xanmod/   ) print $2;
    if ($2 ~ /^linux-kbuild-/  ) print $2;
  }' | sort -u
)

if [[ -n "$img_keep" ]]; then
  purge_pkgs=( $(printf '%s\n' "${purge_pkgs[@]}" | grep -v -x "$img_keep") )
fi

if ((${#purge_pkgs[@]})); then
  log "Purging packages: ${purge_pkgs[*]}"
  apt-get purge -y "${purge_pkgs[@]}" || true
else
  log "No kernel/header packages to purge."
fi

echo

###############################################################################
# 3) 精准清理 /boot：删除非当前版本的 vmlinuz/initrd
###############################################################################
for f in /boot/vmlinuz-* /boot/initrd.img-*; do
  [[ -e "$f" ]] || continue
  ver="${f##*/}"
  ver="${ver#*-}"   # 提取版本号
  if [[ "$ver" != "$cur" ]]; then
    log "Removing /boot/$(basename "$f")"
    rm -f "$f" || true
  fi
done

###############################################################################
# 4) 精准清理 /lib/modules：只删除非当前版本
###############################################################################
for dir in /lib/modules/*; do
  [[ -d "$dir" ]] || continue
  ver="${dir#/lib/modules/}"
  if [[ "$ver" != "$cur" ]]; then
    log "Removing /lib/modules/$ver"
    rm -rf "$dir" || true
  fi
done

###############################################################################
# 5) 清理 /var/lib/initramfs-tools：只删非当前版本
###############################################################################
for f in /var/lib/initramfs-tools/*; do
  [[ -e "$f" ]] || continue
  ver="${f#/var/lib/initramfs-tools/}"
  if [[ "$ver" != "$cur" ]]; then
    log "Removing initramfs-tools record for $ver"
    rm -f "$f" || true
  fi
done

echo

###############################################################################
# 6) 重建当前内核 initramfs（如果 modules 存在）
###############################################################################
if [[ -d "/lib/modules/$cur" ]]; then
  log "Rebuilding initramfs for $cur ..."
  update-initramfs -u -k "$cur" || true
else
  log "SKIP initramfs rebuild: /lib/modules/$cur 不存在（provider 内核）"
fi

###############################################################################
# 7) Update GRUB + autoremove
###############################################################################
if command -v update-grub >/dev/null 2>&1; then
  log "Updating GRUB ..."
  update-grub || true
fi

apt-get autoremove -y --purge || true

echo
log "Done. Only kernel $cur is kept safely."

[[ "$REBOOT" == "1" ]] && { echo "Rebooting..."; reboot; }
