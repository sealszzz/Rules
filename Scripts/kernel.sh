#!/usr/bin/env bash
# kernel.sh — 仅保留“当前正在运行的内核”和“其对应 headers”
# 目标：
#   1) 清理除当前内核以外的所有已安装内核与 headers、工具等版本化包
#   2) 保留元包（meta），确保后续仍可顺利安装/升级/切换其他内核
#   3) 不手工删除 /lib/modules/<ver>（交给 apt purge）
#   4) 清理 /boot、/usr/src、initramfs 残留，但保留当前版本
#
# 适配：Debian 13（含 cloud 内核）+ XanMod（main/lts 等）
# 说明：
#   - 保护的元包举例：linux-image-amd64、linux-image-cloud-amd64、
#     linux-headers-amd64、linux-headers-common、linux-xanmod(-lts|-edge)
#   - 仅 purge 具体“版本化”的包（linux-image-<ver>、linux-headers-<ver> 等）

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行：sudo $0" >&2
    exit 1
  fi
}

apt_lock_wait() {
  # 简单等锁（避免你之前 apt 锁冲突的问题）
  local tries=30
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock >/dev/null 2>&1 ; do
    ((tries--)) || { echo "APT 锁长期占用，退出"; exit 1; }
    sleep 1
  done
}

main() {
  need_root
  apt_lock_wait

  cur="$(uname -r)"
  echo ">>> Current kernel: $cur"
  echo

  # 识别当前内核 image 包名（已考虑 unsigned）
  keep_image_pkg=""
  if dpkg -s "linux-image-$cur" >/dev/null 2>&1; then
    keep_image_pkg="linux-image-$cur"
  elif dpkg -s "linux-image-unsigned-$cur" >/dev/null 2>&1; then
    keep_image_pkg="linux-image-unsigned-$cur"
  fi

  # 保护的元包（保留它们，保证未来升级/切换不受影响）
  # 注：存在与否都 OK，后面会“如果已安装则跳过 purge”
  protected_metas=(
    linux-image-amd64
    linux-image-cloud-amd64
    linux-headers-amd64
    linux-headers-common
    linux-tools-common
    linux-base
    linux-libc-dev
    linux-xanmod
    linux-xanmod-lts
    linux-xanmod-edge
  )

  # 列出所有候选清理的“版本化”包
  # 注意：不把元包放进候选
  mapfile -t all_versioned_pkgs < <(
    dpkg -l 2>/dev/null | awk '/^ii/{print $2}' | grep -E \
      '^(linux-image(-unsigned)?-[0-9]|linux-headers-[0-9]|linux-(kbuild|tools|source)-[0-9])'
  )

  # 过滤得到真正要 purge 的包：排除当前 image & 当前 headers
  purge_pkgs=()
  for p in "${all_versioned_pkgs[@]}"; do
    # 跳过当前正在运行的 image 包
    [[ -n "$keep_image_pkg" && "$p" == "$keep_image_pkg" ]] && continue
    # 跳过当前 headers 包
    [[ "$p" == "linux-headers-$cur" ]] && continue
    purge_pkgs+=("$p")
  done

  # 最后再把“可能被误纳入的元包”过滤掉（双保险）
  filtered_pkgs=()
  for p in "${purge_pkgs[@]}"; do
    skip=0
    for meta in "${protected_metas[@]}"; do
      if [[ "$p" == "$meta" ]]; then
        skip=1; break
      fi
    done
    (( skip == 0 )) && filtered_pkgs+=("$p")
  done

  echo ">>> Keep image pkg : ${keep_image_pkg:-<none>}"
  echo ">>> Keep headers   : linux-headers-$cur (若已安装)"
  echo

  echo ">>> Purge packages (${#filtered_pkgs[@]}):"
  if ((${#filtered_pkgs[@]})); then
    printf '    %s\n' "${filtered_pkgs[@]}"
  else
    echo "    <none>"
  fi
  echo

  if ((${#filtered_pkgs[@]})); then
    apt-get purge -y "${filtered_pkgs[@]}" || true
  fi

  # ========== 清理残留（谨慎保留当前版本） ==========
  # 1) /usr/src：仅删除非当前版本的 headers/source 目录
  if ls -d /usr/src/linux-headers-* >/dev/null 2>&1; then
    for d in /usr/src/linux-headers-*; do
      ver="${d##*/linux-headers-}"
      [[ "$ver" == "$cur" ]] && continue
      echo ">>> Removing $d"
      rm -rf "$d"
    done
  fi
  if ls -d /usr/src/linux-source-* >/dev/null 2>&1; then
    for d in /usr/src/linux-source-*; do
      echo ">>> Removing $d"
      rm -rf "$d"
    done
  fi

  # 2) /var/lib/initramfs-tools：仅删除非当前版本的缓存
  if ls /var/lib/initramfs-tools/* >/dev/null 2>&1; then
    for f in /var/lib/initramfs-tools/*; do
      base="$(basename "$f")"
      [[ "$base" == "$cur" ]] && continue
      echo ">>> Removing /var/lib/initramfs-tools/$base"
      rm -f "$f"
    done
  fi

  # 3) /boot：删除非当前版本的文件（vmlinuz/initrd/System.map/config）
  for pat in vmlinuz initrd.img System.map config; do
    for f in /boot/${pat}-*; do
      [[ -e "$f" ]] || continue
      ver="${f##*/${pat}-}"
      [[ "$ver" == "$cur" ]] && continue
      echo ">>> Removing /boot/$(basename "$f")"
      rm -f "$f"
    done
  done

  # 4) 重建当前内核 initramfs（以防前面清理影响）
  echo ">>> Rebuilding initramfs for $cur"
  update-initramfs -u -k "$cur" || true

  # 5) 更新 GRUB 菜单
  echo ">>> Updating GRUB"
  update-grub || true

  # 6) APT 收尾
  apt-get -y autoremove --purge || true
  apt-get -y autoclean || true
  apt-get -y clean || true

  echo
  echo ">>> Done. Only current kernel kept: $cur"
}

main "$@"
