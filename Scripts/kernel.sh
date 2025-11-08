#!/usr/bin/env bash
# keep-current-kernel.sh
# 只保留“当前正在运行的 kernel image”；清理其它内核 / 所有 headers / 元包
# 环境变量：
#   REBOOT=1    # 完成后自动重启（默认 1；设为 0 则不重启）

set -euo pipefail
: "${REBOOT:=1}"

log(){ printf '>>> %s\n' "$*"; }

cur="$(uname -r)"                                  # 例：6.12.57-x64v3-xanmod1
img_keep=""                                         # 要保留的 image 包名

# 1) 精确定位“当前正在运行”的 image 包（优先 signed，再尝试 unsigned，再兜底匹配）
if dpkg -s "linux-image-${cur}" >/dev/null 2>&1; then
  img_keep="linux-image-${cur}"
elif dpkg -s "linux-image-unsigned-${cur}" >/dev/null 2>&1; then
  img_keep="linux-image-unsigned-${cur}"
else
  img_keep="$(dpkg -l 2>/dev/null \
    | awk '/^ii/ && $2 ~ /^linux-image(-unsigned)?-/{print $2}' \
    | grep -F -- "-$cur" | head -n1 || true)"
fi

[[ -n "$img_keep" ]] || { echo "!!! 未找到与正在运行内核($cur) 对应的 image 包，安全退出。"; exit 1; }

log "Running kernel  : $cur"
log "Keep image pkg  : $img_keep"
echo

# 2) 计算清理清单（除当前 image 外：清理所有 linux-image* / 所有 linux-headers* / 常见元包）
mapfile -t purge_pkgs < <(
  dpkg -l 2>/dev/null | awk '/^ii/{
    if ($2 ~ /^(linux-(image|headers)(-|$))/)                        print $2;
    if ($2 ~ /^(linux-(image|headers)-(amd64|cloud-amd64|unsigned|common))$/) print $2;
    if ($2 ~ /^linux-xanmod.*/ || $2 ~ /^linux-image-virtual$/ || $2 ~ /^linux-kbuild-.*/) print $2;
  }' | sort -u | grep -v -x -- "$img_keep"
)

# 强制把“当前版本的 headers”也放进清单（如果装了）
if dpkg -s "linux-headers-$cur" >/dev/null 2>&1; then
  printf '%s\n' "${purge_pkgs[@]}" | grep -qx "linux-headers-$cur" || purge_pkgs+=("linux-headers-$cur")
fi

if ((${#purge_pkgs[@]})); then
  log "Packages to purge: ${purge_pkgs[*]}"
  apt-get purge -y "${purge_pkgs[@]}"
else
  log "No extra kernel/header/meta packages to purge."
fi
echo

# 3) 清理非当前版本的残留（绝不动 $cur）
#    - /boot: 清理 vmlinuz-<v> / initrd.img-<v>
#    - /lib/modules: 清理非当前版本目录
#    - /var/lib/initramfs-tools: 清理旧版本记录
mapfile -t leftovers < <(
  { ls -1 /boot/vmlinuz-* 2>/dev/null || true;
    ls -1 /boot/initrd.img-* 2>/dev/null || true;
    ls -1d /lib/modules/* 2>/dev/null || true; } |
  sed -E 's@.*/(vmlinuz-|initrd\.img-|modules/)?@@' |
  grep -E '^[0-9]+' | sort -u | grep -v -F -- "$cur" || true
)

for v in "${leftovers[@]:-}"; do
  log "Cleanup leftovers of $v"
  update-initramfs -d -k "$v" 2>/dev/null || true
  rm -f  "/boot/vmlinuz-$v" "/boot/initrd.img-$v" 2>/dev/null || true
  rm -rf "/lib/modules/$v" 2>/dev/null || true
  rm -f  "/var/lib/initramfs-tools/$v" 2>/dev/null || true
done
echo

# 4) 若 /lib/modules/$cur 存在再重建 initramfs；否则跳过，避免无模块报错
if [[ -d "/lib/modules/$cur" ]]; then
  log "Rebuilding initramfs for $cur ..."
  update-initramfs -u -k "$cur" || true
else
  log "Skip rebuild: /lib/modules/$cur 不存在（内核为纯内建或模块目录不在本机）"
fi

# 刷新 GRUB & 自动清理依赖
if command -v update-grub >/dev/null 2>&1; then
  log "Updating GRUB ..."
  update-grub || true
elif command -v grub-mkconfig >/dev/null 2>&1; then
  grub-mkconfig -o /boot/grub/grub.cfg || true
fi
apt-get autoremove -y --purge || true
echo

log "Done. Kept only: $img_keep (kernel $cur). All other kernels & headers removed."
[[ "$REBOOT" == "1" ]] && { echo "Rebooting..."; systemctl reboot || reboot; }
