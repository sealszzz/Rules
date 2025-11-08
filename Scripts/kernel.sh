#!/usr/bin/env bash
# purge-kernels-headers.sh — 只保留正在运行内核；彻底清理 headers / 元包 / 残留
# 绝不手动删除 /lib/modules/*
#
# 开关（按需覆盖）：
#   KEEP_CUR_HEADERS=0   # 是否保留当前内核的 headers 包
#   KEEP_META=0          # 是否保留 linux-image-*-amd64 / headers-*-amd64 等元包
#   KEEP_CLOUD_META=0    # 是否单独保留 cloud 元包（image/headers-cloud-amd64）
#   REBOOT=1             # 完成后重启
set -euo pipefail
: "${KEEP_CUR_HEADERS:=0}"
: "${KEEP_META:=0}"
: "${KEEP_CLOUD_META:=0}"
: "${REBOOT:=1}"

log(){ printf '>>> %s\n' "$*"; }

cur="$(uname -r)"
log "Running kernel : $cur"

# 检查当前正在使用的镜像包（若为 provider 内核则为空）
img_keep=""
if dpkg -s "linux-image-${cur}" >/dev/null 2>&1; then
  img_keep="linux-image-${cur}"
elif dpkg -s "linux-image-unsigned-${cur}" >/dev/null 2>&1; then
  img_keep="linux-image-unsigned-${cur}"
fi
log "Keep image pkg : ${img_keep:-<none (provider kernel)>}"
echo

# 收集所有已安装的 linux* 相关包
mapfile -t all_linux_pkgs < <(
  dpkg-query -W -f='${Package} ${Status}\n' 'linux-*' 2>/dev/null \
  | awk '$2=="install" && $3=="ok" && $4=="installed"{print $1}' \
  | sort -u
)

# 清理目标模式（headers/工具链/源码/工具等；包含 meta）
patterns=(
  '^linux-image-'
  '^linux-image-unsigned-'
  '^linux-headers-'
  '^linux-compiler-'
  '^linux-kbuild-'
  '^linux-source-'
  '^linux-tools-'
  '^linux-xanmod'
)

# 常见 meta 包（按开关决定是否保留）
meta_candidates=(
  'linux-image-amd64'
  'linux-image-cloud-amd64'
  'linux-headers-amd64'
  'linux-headers-cloud-amd64'
  'linux-xanmod'
  'linux-xanmod-x64v3'
)

# 生成初步待清单
purge_pkgs=()
for p in "${all_linux_pkgs[@]}"; do
  for pat in "${patterns[@]}"; do
    if [[ "$p" =~ $pat ]]; then
      purge_pkgs+=("$p")
      break
    fi
  done
done
purge_pkgs=($(printf '%s\n' "${purge_pkgs[@]}" | sort -u))

# 处理 meta 包保留策略
if (( KEEP_META == 0 )); then
  purge_pkgs+=("${meta_candidates[@]}")
else
  # KEEP_META=1：保留全部 meta。若只想保留 cloud meta：
  if (( KEEP_CLOUD_META == 1 )); then
    tmp=()
    for p in "${purge_pkgs[@]}"; do
      case "$p" in
        linux-image-amd64|linux-headers-amd64|linux-xanmod|linux-xanmod-x64v3)
          continue
        ;;
      esac
      tmp+=("$p")
    done
    purge_pkgs=("${tmp[@]}")
  fi
fi

# 永远保留“当前正在运行”的镜像包（若存在）
if [[ -n "$img_keep" ]]; then
  purge_pkgs=( $(printf '%s\n' "${purge_pkgs[@]}" | grep -v -x "$img_keep" || true) )
fi

# 是否保留当前内核 headers
if (( KEEP_CUR_HEADERS == 1 )); then
  purge_pkgs=( $(printf '%s\n' "${purge_pkgs[@]}" | grep -v -x "linux-headers-$cur" || true) )
fi

# 去重
purge_pkgs=($(printf '%s\n' "${purge_pkgs[@]}" | sort -u))

# 清理 dpkg 残留（rc 状态）
mapfile -t rc_pkgs < <(dpkg -l 'linux-*' 2>/dev/null | awk '/^rc/{print $2}')
if ((${#rc_pkgs[@]})); then
  log "Purging residual config (rc): ${rc_pkgs[*]}"
  dpkg -P "${rc_pkgs[@]}" || true
fi

# 执行清理（脚本不手动删 /lib/modules/*）
if ((${#purge_pkgs[@]})); then
  log "Purging packages: ${purge_pkgs[*]}"
  apt-get purge -y "${purge_pkgs[@]}" || true
else
  log "No linux-* packages to purge by patterns."
fi
echo

# 清理 /boot 中旧版本文件（不影响 /lib/modules/*）
for f in /boot/vmlinuz-* /boot/initrd.img-*; do
  [[ -e "$f" ]] || continue
  ver="${f##*/}"; ver="${ver#*-}"
  if [[ "$ver" != "$cur" ]]; then
    log "Removing /boot/$(basename "$f")"
    rm -f -- "$f" || true
  fi
done

# 清理 initramfs-tools 记录（不删除 /lib/modules/*）
for f in /var/lib/initramfs-tools/*; do
  [[ -e "$f" ]] || continue
  ver="${f#/var/lib/initramfs-tools/}"
  if [[ "$ver" != "$cur" ]]; then
    log "Removing initramfs-tools record for $ver"
    rm -f -- "$f" || true
  fi
done

# 强制移除 /usr/src 下 headers / source 目录
if compgen -G "/usr/src/linux-headers-*">/dev/null; then
  for d in /usr/src/linux-headers-*; do
    [[ -d "$d" ]] || continue
    log "Removing $d"
    rm -rf -- "$d" || true
  done
fi
if compgen -G "/usr/src/linux-source-*">/dev/null; then
  for d in /usr/src/linux-source-*; do
    [[ -d "$d" ]] || continue
    log "Removing $d"
    rm -rf -- "$d" || true
  done
fi
echo

# 存在当前内核 modules 时重建 initramfs（仅检查存在性，不做删除）
if [[ -d "/lib/modules/$cur" ]]; then
  log "Rebuilding initramfs for $cur ..."
  update-initramfs -u -k "$cur" || true
else
  log "SKIP initramfs rebuild: /lib/modules/$cur 不存在（provider 内核）"
fi

# 更新 GRUB
if command -v update-grub >/dev/null 2>&1; then
  log "Updating GRUB ..."
  update-grub || true
elif command -v grub-mkconfig >/dev/null 2>&1; then
  grub-mkconfig -o /boot/grub/grub.cfg || true
fi

apt-get -y autoremove --purge || true
apt-get -y autoclean || true
echo

# 汇总
kept="${img_keep:-<provider kernel>}"
if (( KEEP_CUR_HEADERS == 1 )) && dpkg -s "linux-headers-$cur" >/dev/null 2>&1; then
  kept="$kept + linux-headers-$cur"
fi
log "Done. /lib/modules/* 未做任何删除操作。Kept: $kept (running $cur)."

# 可选重启
if [[ "$REBOOT" == "1" ]]; then
  echo "Rebooting in 5s..."
  sleep 5
  systemctl reboot || reboot
fi
