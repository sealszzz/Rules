#!/usr/bin/env bash
# keep2kernels-mini.sh
# 目标：仅保留已安装中的 "xanmod 最新" + "cloud 最新"，其余全部清理；
# 菜单：1) 清理并切换到 xanmod 后重启；2) 清理并切换到 cloud 后重启；0) 退出
# 备注：不考虑/不保留正在运行内核；假定使用 GRUB（无 GRUB 时仅清理，不切换默认项）。

set -euo pipefail

log()  { printf '>>> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }

# --------- 枚举 & 挑最新（两条线） ---------
declare -A PKG_VER PKG_FAM PKG_REL
CLOUD_KEEP=""; XANMOD_KEEP=""
KEEP_PKGS=(); KEEP_VERS=()
PURGE_PKGS=()

collect_packages() {
  PKG_VER=(); PKG_FAM=(); PKG_REL=()
  while IFS=$'\t' read -r pkg ver; do
    [[ -z "${pkg:-}" || -z "${ver:-}" ]] && continue
    [[ "$pkg" =~ ^linux-image(-unsigned)?-[0-9] ]] || continue
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

compute_keep_and_purge() {
  CLOUD_KEEP="$(pick_latest_pkg CLOUD || true)"
  XANMOD_KEEP="$(pick_latest_pkg XANMOD || true)"

  KEEP_PKGS=(); KEEP_VERS=(); PURGE_PKGS=()
  [[ -n "$CLOUD_KEEP"  ]] && { KEEP_PKGS+=("$CLOUD_KEEP");  KEEP_VERS+=("${PKG_REL[$CLOUD_KEEP]}"); }
  [[ -n "$XANMOD_KEEP" ]] && { KEEP_PKGS+=("$XANMOD_KEEP"); KEEP_VERS+=("${PKG_REL[$XANMOD_KEEP]}"); }

  for p in "${!PKG_VER[@]}"; do
    local keep=0
    for k in "${KEEP_PKGS[@]:-}"; do [[ "$p" == "$k" ]] && { keep=1; break; }; done
    (( keep == 0 )) && PURGE_PKGS+=("$p")
  done

  log "Cloud latest : ${CLOUD_KEEP:-<none>}"
  log "XanMod latest: ${XANMOD_KEEP:-<none>}"
  log "Keep images  : ${KEEP_PKGS[*]:-<none>}"
  log "Purge images : ${PURGE_PKGS[*]:-<none>}"
}

purge_unkept() {
  ((${#PURGE_PKGS[@]})) && apt-get purge -y "${PURGE_PKGS[@]}" || true
}

sweep_leftovers() {
  # 找系统中残留的版本（/boot 与 /lib/modules），凡是不在 KEEP_VERS 里都删
  mapfile -t seen < <(
    { ls -1 /boot/vmlinuz-* 2>/dev/null || true; ls -1d /lib/modules/* 2>/dev/null || true; } |
    sed -E 's@.*/(vmlinuz-|modules/)?@@' | sed 's@^initrd\.img-@@' |
    grep -E '^[0-9]+\.' | sort -u
  )
  for v in "${seen[@]:-}"; do
    local keep=0
    for kv in "${KEEP_VERS[@]:-}"; do [[ "$v" == "$kv" ]] && { keep=1; break; }; done
    (( keep == 1 )) && continue
    log "Leftover cleanup: $v"
    update-initramfs -d -k "$v" || true
    rm -f  "/boot/vmlinuz-$v" "/boot/initrd.img-$v" 2>/dev/null || true
    rm -rf "/lib/modules/$v" 2>/dev/null || true
    rm -f  "/var/lib/initramfs-tools/$v" 2>/dev/null || true
  done
}

rebuild_initramfs_and_grub() {
  log "Rebuilding initramfs (remaining kernels) ..."
  update-initramfs -u -k all || true
  if command -v update-grub >/dev/null 2>&1; then
    log "Updating GRUB ..."
    update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg
  else
    warn "No GRUB refresher found (update-grub/grub-mkconfig)."
  fi
  apt-get autoremove -y --purge || true
}

# ---------------- GRUB 增强：保存默认、读取默认、精确匹配路径、设置默认 ----------------

ensure_grub_saved_default() {
  command -v grub-set-default >/dev/null 2>&1 || { warn "grub-set-default not found."; return 1; }
  local cfg="/etc/default/grub"
  if [[ -f "$cfg" ]]; then
    grep -q '^GRUB_DEFAULT=saved' "$cfg" || sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/;t; $aGRUB_DEFAULT=saved' "$cfg"
    grep -q '^GRUB_SAVEDEFAULT=true' "$cfg" || sed -i 's/^#\?GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/;t; $aGRUB_SAVEDEFAULT=true' "$cfg"
  fi
  update-grub 2>/dev/null || true
}

grub_get_saved_default() {
  command -v grub-editenv >/dev/null 2>&1 || { echo ""; return 0; }
  local d; d="$(grub-editenv list 2>/dev/null | awk -F= '/^saved_entry=/{print $2; exit}')" || true
  echo "${d:-}"
}

# 返回完整 menu path：若在子菜单中返回 "子菜单>条目"，否则返回 "条目"
find_grub_entry_path_by_version() {
  local ver="$1" grubcfg="/boot/grub/grub.cfg"
  [[ -f "$grubcfg" ]] || { warn "Missing $grubcfg"; return 1; }

  local path
  path="$(awk -v v="$ver" '
    BEGIN{FS="\""; level=0; subname=""}
    /^[[:space:]]*submenu[[:space:]]+/ { subname=$2; next }
    /\{/ { level++ }
    /\}/ { if(level>0) level--; if(level==0) subname="" }
    /^[[:space:]]*menuentry[[:space:]]+/ {
      title=$2
      if (title !~ /recovery/ && title ~ ("Linux " v)) {
        if (subname != "") { print subname ">" title; exit }
        else { print title; exit }
      }
    }
  ' "$grubcfg")"

  if [[ -n "$path" ]]; then
    echo "$path"; return 0
  fi

  # 兜底：顶层也可能直接有具体版本
  path="$(awk -v v="$ver" -F\" '
    /^[[:space:]]*menuentry[[:space:]]+/ {
      t=$2; if (t !~ /recovery/ && t ~ ("Linux " v)) { print t; exit }
  }' "$grubcfg")"

  [[ -n "$path" ]] && { echo "$path"; return 0; }

  return 1
}

# 设置 GRUB 默认为指定版本（若已是默认或正在运行同版本则跳过）
grub_set_default_by_version() {
  local ver="$1"
  local running saved
  running="$(uname -r)"
  saved="$(grub_get_saved_default)"

  if [[ "$running" == "$ver" && "$saved" == *"$ver"* ]]; then
    log "GRUB default already points to $ver and it is the running kernel. Skip setting."
    return 0
  fi

  local path
  if ! path="$(find_grub_entry_path_by_version "$ver")"; then
    warn "No GRUB menuentry found for Linux $ver"
    return 1
  fi

  log "grub-set-default: ${path}"
  grub-set-default "${path}" || { warn "grub-set-default failed for $ver"; return 1; }
  update-grub 2>/dev/null || true
  return 0
}

# ---------------- 执行：清理 + 切换 ----------------

do_cleanup_and_switch() {
  local target_family="$1" target_pkg="" target_ver=""
  collect_packages
  compute_keep_and_purge

  purge_unkept
  sweep_leftovers
  rebuild_initramfs_and_grub

  # 重新收集一次，以获取最终存在的版本号
  collect_packages
  compute_keep_and_purge

  if [[ "$target_family" == "xanmod" ]]; then
    target_pkg="$XANMOD_KEEP"
  else
    target_pkg="$CLOUD_KEEP"
  fi

  if [[ -z "$target_pkg" ]]; then
    warn "No ${target_family^^} kernel installed; cannot switch default."
    return 1
  fi

  target_ver="${PKG_REL[$target_pkg]}"

  ensure_grub_saved_default || true

  # 若当前正在运行同版本，则无需修改 GRUB 默认项
  if [[ "$(uname -r)" == "$target_ver" ]]; then
    log "Running kernel is already $target_ver; skip changing GRUB default."
  else
    grub_set_default_by_version "$target_ver" || warn "Failed to set GRUB default to $target_ver"
  fi

  log "Default boot set to ${target_family^^} ($target_ver). Rebooting ..."
  sleep 1
  systemctl reboot
}

# ---------------- 简单菜单 ----------------
while :; do
  echo
  echo "====== Keep2Kernels Mini ======"
  echo "1) 清理 -> 切换到 XanMod 最新 -> 重启"
  echo "2) 清理 -> 切换到 Cloud 最新 -> 重启"
  echo "0) 退出"
  read -rp "选择: " ans
  case "${ans:-}" in
    1) do_cleanup_and_switch xanmod || read -rp "操作失败，按回车返回菜单..." _ ;;
    2) do_cleanup_and_switch cloud  || read -rp "操作失败，按回车返回菜单..." _ ;;
    0) echo "Bye."; exit 0 ;;
    *) echo "无效选择";;
  esac
done
