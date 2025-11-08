#!/usr/bin/env bash
# kernel.sh
# 仅保留“当前正在运行的 kernel image”，清理所有 headers / 其它内核 / 常见元包
# 适用：Debian 13 / XanMod / Cloud；假定使用 GRUB
# 可选：DRY_RUN=1 只打印不执行

set -euo pipefail
log(){ printf '>>> %s\n' "$*"; }
warn(){ printf '!!! %s\n' "$*" >&2; }
run(){ if [[ "${DRY_RUN:-0}" == "1" ]]; then echo "+ $*"; else eval "$@"; fi; }

cur="$(uname -r)"                                      # 例：6.12.57-x64v3-xanmod1 或 6.12.48+deb13-cloud-amd64
img_keep=""                                            # 要保留的 image 包名

# 尝试匹配已安装的 image 包（优先精确匹配）
if dpkg -s "linux-image-${cur}" >/dev/null 2>&1; then
  img_keep="linux-image-${cur}"
elif dpkg -s "linux-image-unsigned-${cur}" >/dev/null 2>&1; then
  img_keep="linux-image-unsigned-${cur}"
else
  # 兜底：从已安装 image 中按版本后缀匹配
  img_keep="$(dpkg -l 2>/dev/null | awk -v v="$cur" '/^ii/ && $2 ~ /^linux-image(-unsigned)?-/ {print $2}' | grep -F -- "-$cur" | head -n1 || true)"
fi

log "Running kernel : ${cur}"
[[ -n "$img_keep" ]] && log "Keep image pkg : ${img_keep}" || warn "未找到与当前内核匹配的 linux-image 包（将仅做残留清理）"

# 1) 计算需要清理的包：
#    - 所有 linux-headers*（包含当前版本）
#    - 所有其它 linux-image*（不等于要保留的 image）
#    - 常见元包（避免将来把 headers 又装回来）
mapfile -t purge_pkgs < <(
  dpkg -l 2>/dev/null |
  awk '/^ii/ {
    if ($2 ~ /^(linux-(image|headers)(-|$))/) print $2;
    if ($2 ~ /^(linux-(image|headers)-(amd64|cloud-amd64|unsigned|common)|linux-xanmod.*|linux-image-virtual|linux-kbuild-.*)$/) print $2;
  }' | sort -u | {
    if [[ -n "$img_keep" ]]; then
      grep -v -x -- "$img_keep"
    else
      cat
    fi
  }
)

if ((${#purge_pkgs[@]})); then
  log "Packages to purge: ${purge_pkgs[*]}"
  run "apt-get purge -y ${purge_pkgs[*]}"
else
  log "No extra kernel/header/meta packages to purge."
fi

# 2) 扫除旧版本残留（/boot、/lib/modules、/usr/src、initramfs-tools）
mapfile -t leftovers < <(
  { ls -1 /boot/vmlinuz-* 2>/dev/null || true; ls -1 /boot/initrd.img-* 2>/dev/null || true; ls -1d /lib/modules/* 2>/dev/null || true; } |
  sed -E 's@.*/(vmlinuz-|initrd\.img-|modules/)?@@' |
  grep -E '^[0-9]+' | sort -u | grep -v -F -- "$cur" || true
)
for v in "${leftovers[@]:-}"; do
  log "Cleanup leftovers of ${v}"
  run "update-initramfs -d -k ${v} 2>/dev/null || true"
  run "rm -f  /boot/vmlinuz-${v} /boot/initrd.img-${v} 2>/dev/null || true"
  run "rm -rf /lib/modules/${v} 2>/dev/null || true"
  run "rm -f  /var/lib/initramfs-tools/${v} 2>/dev/null || true"
done

# /usr/src 下的 headers 目录（包括当前版本在内全部删除）
if ls -1 /usr/src 2>/dev/null | grep -q '^linux-headers-'; then
  log "Removing /usr/src/linux-headers-* leftovers"
  run "rm -rf /usr/src/linux-headers-* 2>/dev/null || true"
fi

# 3) 为当前内核重建 initramfs，并刷新 GRUB & 自动清理依赖
log "Rebuilding initramfs for ${cur} ..."
run "update-initramfs -u -k '${cur}' || true"

if command -v update-grub >/dev/null 2>&1; then
  log "Updating GRUB ..."
  run "update-grub || true"
elif command -v grub-mkconfig >/dev/null 2>&1; then
  run "grub-mkconfig -o /boot/grub/grub.cfg || true"
fi

run "apt-get autoremove -y --purge || true"
log "Done. Kept only the running kernel image (${cur}); all headers removed."
