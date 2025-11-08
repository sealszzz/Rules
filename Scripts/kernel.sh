#!/usr/bin/env bash
# keep-current-kernel.sh
# 只保留“当前正在运行的 kernel image”，可选是否清理所有 headers；完成后可选自动重启
# 环境变量：
#   PURGE_HEADERS=1  # 1=清理所有 linux-headers*（默认 1）
#   REBOOT=1         # 1=完成后自动重启（默认 1）

set -euo pipefail
: "${PURGE_HEADERS:=1}"
: "${REBOOT:=1}"

log(){ printf '>>> %s\n' "$*"; }
run(){ eval "$@"; }

cur="$(uname -r)"                              # 例如：6.12.57-x64v3-xanmod1
img_keep=""                                    # linux-image(-unsigned)-$cur

# 1) 找到应保留的“正在运行内核”的 image 包（绝不删除它）
if dpkg -s "linux-image-${cur}" >/dev/null 2>&1; then
  img_keep="linux-image-${cur}"
elif dpkg -s "linux-image-unsigned-${cur}" >/dev/null 2>&1; then
  img_keep="linux-image-unsigned-${cur}"
else
  img_keep="$(dpkg -l 2>/dev/null | awk -v v="$cur" '/^ii/ && $2 ~ /^linux-image(-unsigned)?-/{print $2}' | grep -F -- "-$cur" | head -n1 || true)"
fi
[ -n "$img_keep" ] || { echo "!!! 未找到与正在运行内核($cur) 对应的 image 包，安全退出。"; exit 1; }

log "Running kernel : $cur"
log "Keep image pkg : $img_keep"
[ "$PURGE_HEADERS" = "1" ] && log "Mode           : 清理所有 headers" || log "Mode           : 不动 headers"

# 2) 计算待清理的包（永远排除当前 image；可选包含全部 headers）
if [ "$PURGE_HEADERS" = "1" ]; then
  awk_pat='/^ii/ && ($2 ~ /^(linux-(image|headers)(-|$)|linux-(image|headers)-(amd64|cloud-amd64|unsigned|common)|linux-xanmod.*|linux-image-virtual|linux-kbuild-.*)$/)'
else
  awk_pat='/^ii/ && ($2 ~ /^(linux-image(-|$)|linux-image-(amd64|cloud-amd64|unsigned|common)|linux-xanmod.*|linux-image-virtual)$/)'
fi
mapfile -t purge_pkgs < <( dpkg -l 2>/dev/null | awk "$awk_pat {print \$2}" | sort -u | grep -v -x -- "$img_keep" )

# 如需清 headers，确保把“当前版本 headers”也纳入清单（有些仓库里它不是元包依赖）
if [ "$PURGE_HEADERS" = "1" ] && dpkg -s "linux-headers-$cur" >/dev/null 2>&1; then
  if ! printf '%s\n' "${purge_pkgs[@]}" | grep -qx "linux-headers-$cur"; then
    purge_pkgs+=("linux-headers-$cur")
  fi
fi

if ((${#purge_pkgs[@]})); then
  log "Packages to purge: ${purge_pkgs[*]}"
  run "apt-get purge -y ${purge_pkgs[*]}"
else
  log "No extra kernel packages to purge."
fi

# 3) 清理非当前版本的残留（/boot、/lib/modules、initramfs-tools 记录）
#    注意：显式排除当前版本，且过滤空行，避免出现空版本号
mapfile -t leftovers < <(
  { ls -1 /boot/vmlinuz-*        2>/dev/null || true;
    ls -1 /boot/initrd.img-*     2>/dev/null || true;
    ls -1d /lib/modules/*        2>/dev/null || true; } |
  sed -E 's@.*/(vmlinuz-|initrd\.img-|modules/)?@@' |
  grep -E '^[0-9]+' | sort -u | grep -v -F -- "$cur" || true
)
for v in "${leftovers[@]:-}"; do
  [ -n "$v" ] || continue
  log "Cleanup leftovers of ${v}"
  run "update-initramfs -d -k ${v} 2>/dev/null || true"
  run "rm -f /boot/vmlinuz-${v} /boot/initrd.img-${v} 2>/dev/null || true"
  run "rm -rf /lib/modules/${v} 2>/dev/null || true"
  run "rm -f /var/lib/initramfs-tools/${v} 2>/dev/null || true"
done

# 4) （可选）彻底清 /usr/src 下 headers 目录
if [ "$PURGE_HEADERS" = "1" ] && ls -1 /usr/src 2>/dev/null | grep -q '^linux-headers-'; then
  log "Removing /usr/src/linux-headers-* leftovers"
  run "rm -rf /usr/src/linux-headers-* 2>/dev/null || true"
fi

# 5) 为当前内核重建 initramfs、刷新 GRUB、自动清理依赖
log "Rebuilding initramfs for ${cur} ..."
if [ -d "/lib/modules/${cur}" ]; then
  run "update-initramfs -u -k '${cur}' || true"
else
  # 某些发行内核为极简/无模块布局，避免 depmod 报错刷屏
  run "update-initramfs -u -k '${cur}' || true"
fi
command -v update-grub     >/dev/null 2>&1 && run "update-grub || true" || \
command -v grub-mkconfig   >/dev/null 2>&1 && run "grub-mkconfig -o /boot/grub/grub.cfg || true"
run "apt-get autoremove -y --purge || true"

log "Done. Kept kernel image: ${cur}; headers $( [ "$PURGE_HEADERS" = "1" ] && echo REMOVED || echo KEPT )."
[ "$REBOOT" = "1" ] && { echo "Rebooting..."; systemctl reboot || reboot; }
