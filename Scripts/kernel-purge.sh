#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
command -v fuser >/dev/null 2>&1 || { echo "缺少 fuser，请先安装: apt-get install -y psmisc"; exit 1; }

for _ in {1..30}; do
  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
  fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
  fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
  fuser /var/cache/apt/archives/lock >/dev/null 2>&1 || break
  sleep 1
done

dpkg --configure -a
apt-get -fy install

cur="$(uname -r)"
keep=""
keep_headers=()

for p in "linux-image-$cur" "linux-image-unsigned-$cur"; do
  dpkg -s "$p" >/dev/null 2>&1 && keep="$p"
done
[ -n "$keep" ] || { echo "FATAL: 找不到当前内核对应包: $cur"; exit 1; }

for p in "linux-headers-$cur" "linux-headers-$cur-common"; do
  dpkg -s "$p" >/dev/null 2>&1 && keep_headers+=("$p")
done

mapfile -t pkgs < <(
  dpkg -l | awk '/^ii/{print $2}' | grep -E \
  '^(linux-image(-unsigned)?-[0-9]|linux-headers-[0-9]|linux-(kbuild|tools|source)-[0-9])' || true
)

purge=()
for p in "${pkgs[@]}"; do
  [ "$p" = "$keep" ] && continue
  skip=0
  for h in "${keep_headers[@]}"; do
    [ "$p" = "$h" ] && { skip=1; break; }
  done
  [ "$skip" -eq 0 ] && purge+=("$p")
done

echo ">>> Current kernel: $cur"
echo ">>> Keep image   : $keep"
echo ">>> Keep headers : ${keep_headers[*]:-<none>}"
echo ">>> Purge packages (${#purge[@]}):"
((${#purge[@]})) && printf '    %s\n' "${purge[@]}" || echo "    <none>"
echo

((${#purge[@]})) && apt-get -y purge "${purge[@]}"
apt-get -y autoremove --purge
apt-get -y clean
update-initramfs -u -k "$cur"
update-grub

echo ">>> Done. Only current kernel kept: $cur"
echo ">>> Rebooting now..."
sleep 1
systemctl reboot || reboot
