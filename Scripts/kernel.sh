#!/usr/bin/env bash
# keep-only-current-kernel.sh
# 只保留当前正在运行的内核（XanMod/Cloud 任意），清除所有旧内核版本
# 安全：绝不手动删 /lib/modules，只由 apt purge 删除对应模块

set -euo pipefail

cur="$(uname -r)"
echo ">>> Current kernel: $cur"
echo

# 当前 kernel image 包（可能是 linux-image 或 linux-image-unsigned）
keep_pkg=""
if dpkg -s "linux-image-$cur" >/dev/null 2>&1; then
    keep_pkg="linux-image-$cur"
elif dpkg -s "linux-image-unsigned-$cur" >/dev/null 2>&1; then
    keep_pkg="linux-image-unsigned-$cur"
fi

echo ">>> Keep image pkg: ${keep_pkg:-<none>}"
echo

# 找所有内核 image/header/meta
mapfile -t all_pkgs < <(
  dpkg -l 2>/dev/null | awk '/^ii/{print $2}' | grep -E \
  '^(linux-image|linux-headers|linux-kbuild|linux-tools|linux-source|linux-xanmod)'
)

# 移除当前内核 image / header（如存在）
purge_pkgs=()
for p in "${all_pkgs[@]}"; do
  [[ "$p" == "$keep_pkg" ]] && continue
  [[ "$p" == "linux-headers-$cur" ]] && continue
  purge_pkgs+=("$p")
done

# 输出要清理的包
echo ">>> Purge packages:"
printf '   %s\n' "${purge_pkgs[@]}"
echo

# 执行 purge（APT 会自动删除对应 /lib/modules/<version>）
if ((${#purge_pkgs[@]})); then
  apt-get purge -y "${purge_pkgs[@]}" || true
fi

# 强制删除 headers 残留目录（不影响内核模块）
rm -rf /usr/src/linux-headers-* 2>/dev/null || true
rm -rf /usr/src/linux-source-* 2>/dev/null || true
rm -f  /var/lib/initramfs-tools/* 2>/dev/null || true

# 清 boot 中旧版本文件
for f in /boot/vmlinuz-* /boot/initrd.img-*; do
  [[ -e "$f" ]] || continue
  ver="${f##*/}"
  ver="${ver#*-}"
  [[ "$ver" == "$cur" ]] && continue
  echo ">>> Removing /boot/$(basename "$f")"
  rm -f "$f"
done

# 更新 initramfs & grub
echo ">>> Rebuilding initramfs for $cur"
update-initramfs -u -k "$cur" || true

echo ">>> Updating GRUB"
update-grub || true

apt-get autoremove -y --purge || true
apt-get autoclean -y || true
apt-get clean -y || true

echo
echo ">>> Done. Only current kernel kept: $cur"
