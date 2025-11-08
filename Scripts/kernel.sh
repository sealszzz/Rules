#!/usr/bin/env bash
# keep-current-kernel.sh
# 只保留“当前正在运行的 kernel image”；永不删除正在运行的内核
# 环境变量：
#   DRY_RUN=0/1        # 0=执行；1=仅演示（默认 0）
#   PURGE_HEADERS=0/1  # 1=清理所有 linux-headers*（默认 1）

set -euo pipefail

log(){ printf '>>> %s\n' "$*"; }
warn(){ printf '!!! %s\n' "$*" >&2; }
: "${DRY_RUN:=0}"
: "${PURGE_HEADERS:=1}"
run(){ if [[ "$DRY_RUN" == "1" ]]; then echo "+ $*"; else eval "$@"; fi; }

cur="$(uname -r)"                                  # 例：6.12.57-x64v3-xanmod1 或 6.12.48+deb13-cloud-amd64
img_keep_1="linux-image-${cur}"
img_keep_2="linux-image-unsigned-${cur}"
img_keep=""

# 1) 找到应保留的“正在运行内核”的 image 包
if dpkg -s "$img_keep_1" >/dev/null 2>&1; then
  img_keep="$img_keep_1"
elif dpkg -s "$img_keep_2" >/dev/null 2>&1; then
  img_keep="$img_keep_2"
else
  # 兜底：从已安装 image 中按版本尾巴匹配
  img_keep="$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^linux-image(-unsigned)?-/{print $2}' | grep -F -- "-$cur" | head -n1 || true)"
fi

if [[ -z "$img_keep" ]]; then
  warn "未找到与正在运行内核 ($cur) 对应的 linux-image 包，安全退出（不做任何清理）。"
  exit 1
fi

log "Running kernel : ${cur}"
log "Keep image pkg : ${img_keep}"
[[ "$PURGE_HEADERS" == "1" ]] && log "Mode          : 将清理所有 linux-headers*" || log "Mode          : 不清理 headers"

# 2) 计算待清理包
if [[ "$PURGE_HEADERS" == "1" ]]; then
  awk_pat='/^ii/ && ($2 ~ /^(linux-(image|headers)(-|$)|linux-(image|headers)-(amd64|cloud-amd64|unsigned|common)|linux-xanmod.*|linux-image-virtual|linux-kbuild-.*)$/)'
else
  awk_pat='/^ii/ && ($2 ~ /^(linux-image(-|$)|linux-image-(amd64|cloud-amd64|unsigned|common)|linux-xanmod.*|linux-image-virtual)$/)'
fi

mapfile -t purge_pkgs < <(dpkg -l 2>/dev/null | awk "$awk_pat {print \$2}" | sort -u | grep -v -x -- "$img_keep")

if ((${#purge_pkgs[@]})); then
  log "Packages to purge: ${purge_pkgs[*]}"
  run "apt-get purge -y ${purge_pkgs[*]}"
else
  log "No extra kernel packages to purge."
fi

# 3) 清理非当前版本的残留（/boot、/lib/modules、initramfs-tools）
mapfile -t leftovers < <(
  { ls -1 /boot/vmlinuz-* 2>/dev/null || true;
    ls -1 /boot/initrd.img-* 2>/dev/null || true;
    ls -1d /lib/modules/* 2>/dev/null || true; } |
  sed -E 's@.*/(vmlinuz-|initrd\.img-|modules/)?@@' |
  grep -E '^[0-9]+' | sort -u | grep -v -F -- "$cur" || true
)
for v in "${leftovers[@]:-}"; do
  log "Cleanup leftovers of ${v}"
  run "update-initramfs -d -k ${v} 2>/dev/null || true"
  run "rm -f /boot/vmlinuz-${v} /boot/initrd.img-${v} 2>/dev/null || true"
  run "rm -rf /lib/modules/${v} 2>/dev/null || true"
  run "rm -f /var/lib/initramfs-tools/${v} 2>/dev/null || true"
done

# 4) 可选：/usr/src 下 headers 目录（当 PURGE_HEADERS=1 时）
if [[ "$PURGE_HEADERS" == "1" ]] && ls -1 /usr/src 2>/dev/null | grep -q '^linux-headers-'; then
  log "Removing /usr/src/linux-headers-* leftovers"
  run "rm -rf /usr/src/linux-headers-* 2>/dev/null || true"
fi

# 5) 为当前内核重建 initramfs，并刷新 GRUB；自动清理依赖
log "Rebuilding initramfs for ${cur} ..."
run "update-initramfs -u -k '${cur}' || true"

if command -v update-grub >/dev/null 2>&1; then
  log "Updating GRUB ..."
  run "update-grub || true"
elif command -v grub-mkconfig >/dev/null 2>&1; then
  run "grub-mkconfig -o /boot/grub/grub.cfg || true"
fi

run "apt-get autoremove -y --purge || true"
log "Done. Kept kernel image: ${cur} ; headers $( [[ ${PURGE_HEADERS} == 1 ]] && echo 'REMOVED' || echo 'KEPT/UNCHANGED' )."
