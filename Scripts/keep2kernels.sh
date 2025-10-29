#!/usr/bin/env bash
# keep2kernels.sh
# 只保留 cloud-amd64 与 xanmod 两条线中“已安装的版本化镜像包”的最新版本；清理其余并扫残片；
# 自动检测 UEFI/BIOS，刷新 initramfs 与 GRUB；
# 支持一键把默认启动设置为 cloud/xanmod 最新。
#
# 非交互用法：
#   PLAN_ONLY=1 ./keep2kernels.sh          # 只演练，显示计划
#   ./keep2kernels.sh                       # 清理至“两线最新”，并刷新引导
#   CHOOSE_BOOT=cloud ./keep2kernels.sh     # 仅设置默认启动到 cloud 最新（不清理）
#   CHOOSE_BOOT=xanmod ./keep2kernels.sh    # 仅设置默认启动到 xanmod 最新（不清理）
#
# 交互菜单：直接 ./keep2kernels.sh 会出现菜单（TTY 环境）

set -euo pipefail

: "${PLAN_ONLY:=0}"           # 1=只演练；0=执行
: "${CHOOSE_BOOT:=none}"      # none|cloud|xanmod
: "${NO_MENU:=0}"             # 1=禁止显示菜单（即使是 TTY）

log()  { printf '>>> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }

detect_boot_env() { [[ -d /sys/firmware/efi ]] && echo UEFI || echo BIOS; }
BOOT_ENV="$(detect_boot_env)"
log "Boot environment: ${BOOT_ENV}"

# ---------------- core state (globals) ----------------
declare -A PKG_VER PKG_FAM PKG_REL   # 已安装版本化镜像包 -> {版本号, 家族, uname -r 风格}
CLOUD_KEEP=""                        # cloud 家族保留的包名
XANMOD_KEEP=""                       # xanmod 家族保留的包名
declare -A KEEP_MAP KEEP_VER         # 保留的包名集合 / 保留的 uname -r 版本集合
TO_PURGE=()                          # 待清理的包名数组

collect_packages() {
  PKG_VER=(); PKG_FAM=(); PKG_REL=()
  while IFS=$'\t' read -r pkg ver; do
    [[ -z "${pkg:-}" || -z "${ver:-}" ]] && continue
    [[ "$pkg" =~ ^linux-image(-unsigned)?-[0-9] ]] || continue     # 仅版本化镜像包
    fam="OTHER"
    [[ "$pkg" == *cloud-amd64 ]] && fam="CLOUD"
    [[ "$pkg" == *xanmod*      ]] && fam="XANMOD"
    PKG_VER["$pkg"]="$ver"
    rel="${pkg#linux-image-}"; rel="${rel#linux-image-unsigned-}"
    PKG_REL["$pkg"]="$rel"
    PKG_FAM["$pkg"]="$fam"
  done < <(dpkg-query -W -f='${Package}\t${Version}\n' \
         "linux-image-*" "linux-image-unsigned-*" 2>/dev/null | sort -u || true)
}

pick_latest_pkg() {
  local family="$1" best="" bestv=""
  for p in "${!PKG_VER[@]}"; do
    [[ "${PKG_FAM[$p]}" == "$family" ]] || continue
    if [[ -z "$best" ]] || dpkg --compare-versions "${PKG_VER[$p]}" gt "$bestv"; then
      best="$p"; bestv="${PKG_VER[$p]}"
    fi
  done
  [[ -n "$best" ]] && echo "$best" || true
}

compute_plan() {
  CLOUD_KEEP="$(pick_latest_pkg CLOUD || true)"
  XANMOD_KEEP="$(pick_latest_pkg XANMOD || true)"
  KEEP_MAP=(); KEEP_VER=(); TO_PURGE=()

  [[ -n "${CLOUD_KEEP:-}"  ]] && { KEEP_MAP["$CLOUD_KEEP"]=1;  KEEP_VER["${PKG_REL[$CLOUD_KEEP]}"]=1; }
  [[ -n "${XANMOD_KEEP:-}" ]] && { KEEP_MAP["$XANMOD_KEEP"]=1; KEEP_VER["${PKG_REL[$XANMOD_KEEP]}"]=1; }

  for p in "${!PKG_VER[@]}"; do
    [[ -n "${KEEP_MAP[$p]:-}" ]] || TO_PURGE+=("$p")
  done

  log "Cloud latest : ${CLOUD_KEEP:-<none>}"
  log "XanMod latest: ${XANMOD_KEEP:-<none>}"
  if ((${#KEEP_MAP[@]})); then
    log "Keep images  : $(printf '%s ' "${!KEEP_MAP[@]}")"
  else
    log "Keep images  : <none>"
  fi
  log "Purge images : ${TO_PURGE[*]:-<none>}"
}

purge_unkept() {
  ((${#TO_PURGE[@]})) && apt-get purge -y "${TO_PURGE[@]}"
}

sweep_leftovers() {
  # 扫描系统仍可见的版本（/boot 与 /lib/modules）
  mapfile -t seen < <(
    { ls -1 /boot/vmlinuz-* 2>/dev/null || true; ls -1d /lib/modules/* 2>/dev/null || true; } |
    sed -E 's@.*/(vmlinuz-|modules/)?@@' | sed 's@^initrd\.img-@@' |
    grep -E '^[0-9]+\.' | sort -u
  )
  local strays=()
  for v in "${seen[@]}"; do
    [[ -z "${KEEP_VER[$v]:-}" ]] && strays+=("$v")
  done
  if ((${#strays[@]})); then
    log "Extra cleanup versions: ${strays[*]}"
    # 双保险：若仍有对应包，先 purge
    local maybe=()
    for v in "${strays[@]}"; do
      for n in "linux-image-$v" "linux-image-unsigned-$v"; do
        dpkg -s "$n" >/dev/null 2>&1 && maybe+=("$n")
      done
    done
    ((${#maybe[@]})) && apt-get purge -y "${maybe[@]}"

    # 删除 initramfs 记录与文件残片
    for v in "${strays[@]}"; do
      update-initramfs -d -k "$v" || true
      rm -f  "/boot/vmlinuz-$v" "/boot/initrd.img-$v" 2>/dev/null || true
      rm -rf "/lib/modules/$v" 2>/dev/null || true
      rm -f  "/var/lib/initramfs-tools/$v" 2>/dev/null || true
    done
  fi
}

rebuild_and_update() {
  log "Rebuilding initramfs for remaining kernels ..."
  update-initramfs -u -k all
  if command -v update-grub >/dev/null 2>&1; then
    log "Updating GRUB ..."
    update-grub
  else
    if command -v grub-mkconfig >/dev/null 2>&1; then
      grub-mkconfig -o /boot/grub/grub.cfg
    else
      warn "No update-grub/grub-mkconfig found; skip GRUB refresh."
    fi
  fi
}

ensure_grub_saved_default() {
  command -v grub-set-default >/dev/null 2>&1 || { warn "grub-set-default not found."; return 1; }
  local cfg="/etc/default/grub"
  if [[ -f "$cfg" ]]; then
    grep -q '^GRUB_DEFAULT=saved' "$cfg" || sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/;t; $aGRUB_DEFAULT=saved' "$cfg"
    grep -q '^GRUB_SAVEDEFAULT=true' "$cfg" || sed -i 's/^#\?GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/;t; $aGRUB_SAVEDEFAULT=true' "$cfg"
  fi
  update-grub
}

grub_set_default_by_version() {
  local ver="$1" grubcfg="/boot/grub/grub.cfg"
  [[ -f "$grubcfg" ]] || { warn "Missing $grubcfg"; return 1; }

  # 优先 submenu（Advanced options），匹配非 recovery 的条目
  local submenu entry
  submenu="$(awk -F\" '/^submenu /{print $2; exit}' "$grubcfg")"
  if [[ -n "$submenu" ]]; then
    entry="$(awk -v v="$ver" -F\" '
      /^[[:space:]]*menuentry /{t=$2; if (t !~ /recovery/ && t ~ ("Linux " v)) {print t; exit}}
    ' "$grubcfg")"
    [[ -n "$entry" ]] || { warn "No menuentry with Linux $ver"; return 1; }
    log "grub-set-default: ${submenu}>${entry}"
    grub-set-default "${submenu}>${entry}"
  else
    entry="$(awk -v v="$ver" -F\" '/^menuentry /{t=$2; if (t !~ /recovery/ && t ~ ("Linux " v)) {print t; exit}}' "$grubcfg")"
    [[ -n "$entry" ]] || { warn "No top-level menuentry with Linux $ver"; return 1; }
    log "grub-set-default: ${entry}"
    grub-set-default "${entry}"
  fi
  update-grub
}

choose_default_boot() {
  local family="$1" target=""
  [[ "$family" == "cloud"  ]] && target="$CLOUD_KEEP"
  [[ "$family" == "xanmod" ]] && target="$XANMOD_KEEP"
  [[ -n "$target" ]] || { warn "No $family latest kernel installed; skip setting default."; return 1; }
  ensure_grub_saved_default
  grub_set_default_by_version "${PKG_REL[$target]}" || return 1
  log "Default boot set to $family (${PKG_REL[$target]})."
}

# ---------------- non-interactive flow ----------------
if [[ "$PLAN_ONLY" == "1" || "$CHOOSE_BOOT" != "none" || "$NO_MENU" == "1" || ! -t 0 || ! -t 1 ]]; then
  collect_packages
  compute_plan
  if [[ "$PLAN_ONLY" == "1" ]]; then
    log "PLAN_ONLY=1 -> dry-run only."
    exit 0
  fi
  # 仅切换默认启动，不清理
  if [[ "$CHOOSE_BOOT" == "cloud" || "$CHOOSE_BOOT" == "xanmod" ]]; then
    choose_default_boot "$CHOOSE_BOOT" || true
    exit 0
  fi
  # 默认行为：清理 & 刷新
  purge_unkept
  sweep_leftovers
  rebuild_and_update
  log "Done."
  exit 0
fi

# ---------------- interactive menu ----------------
while :; do
  echo
  echo "====== Keep2Kernels — 菜单 ======"
  echo "1) 仅显示计划（演练）"
  echo "2) 清理至：仅保留 cloud 最新 + xanmod 最新"
  echo "3) 一键：将默认启动设为 cloud 最新"
  echo "4) 一键：将默认启动设为 xanmod 最新"
  echo "5) 清理 + 将默认启动设为 cloud 最新"
  echo "6) 清理 + 将默认启动设为 xanmod 最新"
  echo "0) 退出"
  read -rp "选择: " ans
  case "$ans" in
    1)
      collect_packages
      compute_plan
      echo "（演练模式，不做修改）"
      ;;
    2)
      collect_packages
      compute_plan
      purge_unkept
      sweep_leftovers
      rebuild_and_update
      ;;
    3)
      collect_packages
      compute_plan
      choose_default_boot cloud || true
      ;;
    4)
      collect_packages
      compute_plan
      choose_default_boot xanmod || true
      ;;
    5)
      collect_packages
      compute_plan
      purge_unkept
      sweep_leftovers
      rebuild_and_update
      collect_packages
      compute_plan
      choose_default_boot cloud || true
      ;;
    6)
      collect_packages
      compute_plan
      purge_unkept
      sweep_leftovers
      rebuild_and_update
      collect_packages
      compute_plan
      choose_default_boot xanmod || true
      ;;
    0) echo "Bye."; exit 0 ;;
    *) echo "无效选择";;
  esac
done
