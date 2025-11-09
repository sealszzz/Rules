#!/usr/bin/env bash
# kernel-purge.sh — 最小风控：只用 apt purge 清理当前内核之外的版本
# 目标：
#   * 只保留正在运行的内核及其 headers
#   * 只使用 apt purge / autoremove，不手动 rm 任何文件
#   * 保留 meta 包，保证后续可继续升级/切换其他内核
#
# 适配：Debian 13（含 cloud 内核）+ XanMod（main/lts）

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请用 root 运行：sudo $0" >&2
    exit 1
  fi
}

apt_lock_wait() {
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

  # 找到当前运行内核对应的 image 包名（考虑 unsigned 变体）
  keep_image_pkg=""
  if dpkg -s "linux-image-$cur" >/dev/null 2>&1; then
    keep_image_pkg="linux-image-$cur"
  elif dpkg -s "linux-image-unsigned-$cur" >/dev/null 2>&1; then
    keep_image_pkg="linux-image-unsigned-$cur"
  fi

  # 需要保留的包（当前 image + 当前 headers）
  keep_pkgs=()
  [[ -n "$keep_image_pkg" ]] && keep_pkgs+=("$keep_image_pkg")
  if dpkg -s "linux-headers-$cur" >/dev/null 2>&1; then
    keep_pkgs+=("linux-headers-$cur")
  fi

  # 保护的 meta 包：不要 purge
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

  # 所有“版本化”的 linux 包（候选）
  mapfile -t versioned < <(
    dpkg -l 2>/dev/null | awk '/^ii/{print $2}' | grep -E \
      '^(linux-image(-unsigned)?-[0-9]|linux-headers-[0-9]|linux-(kbuild|tools|source)-[0-9])'
  )

  # 计算需要 purge 的包：版本化包 - (keep + protected metas)
  to_purge=()
  for p in "${versioned[@]}"; do
    # 跳过 keep
    skip=0
    for k in "${keep_pkgs[@]}"; do
      [[ "$p" == "$k" ]] && { skip=1; break; }
    done
    ((skip==1)) && continue

    # 跳过 meta（保险：虽然上面 grep 只抓版本化包，但再过一遍）
    for m in "${protected_metas[@]}"; do
      [[ "$p" == "$m" ]] && { skip=1; break; }
    done
    ((skip==1)) && continue

    to_purge+=("$p")
  done

  echo ">>> Keep image : ${keep_image_pkg:-<none>}"
  echo ">>> Keep header: linux-headers-$cur (如果已安装)"
  echo
  echo ">>> Purge packages (${#to_purge[@]}):"
  if ((${#to_purge[@]})); then
    printf '    %s\n' "${to_purge[@]}"
  else
    echo "    <none>"
  fi
  echo

  if ((${#to_purge[@]})); then
    apt-get purge -y "${to_purge[@]}"
  fi

  # 自动清理依赖（仍然只通过 APT）
  apt-get autoremove -y --purge
  apt-get autoclean -y
  apt-get clean -y

  # 仅刷新 grub（不手动 rm，不 rebuild 其他版本 initramfs）
  update-grub || true

  echo
  echo ">>> Done. Only current kernel kept via apt purge: $cur"
}

main "$@"
