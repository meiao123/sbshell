#!/bin/bash
set -Eeuo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu/Armbian。" >&2; exit 1; }
command -v curl >/dev/null || apt-get update && apt-get install -y curl
apt-get update
apt-get install -y gpg ca-certificates
install -d -o root -g root -m 0755 /etc/apt/keyrings
KEYRING=/etc/apt/keyrings/xanmod-archive-keyring.gpg
TMP_KEY=$(mktemp)
trap 'rm -f "$TMP_KEY"' EXIT
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 https://dl.xanmod.org/archive.key -o "$TMP_KEY"
gpg --batch --dearmor --yes -o "$KEYRING" "$TMP_KEY"
chmod 0644 "$KEYRING"; chown root:root "$KEYRING"
REPO_LIST=/etc/apt/sources.list.d/xanmod-release.list
REPO_ENTRY="deb [signed-by=$KEYRING] https://deb.xanmod.org releases main"
printf '%s\n' "$REPO_ENTRY" > "$REPO_LIST"
chmod 0644 "$REPO_LIST"; chown root:root "$REPO_LIST"
apt-get update
cpu_flags=$(awk -F: '$1 == "flags" {print $2; exit}' /proc/cpuinfo)
has_flags() { local f; for f in "$@"; do grep -qw -- "$f" <<< "$cpu_flags" || return 1; done; }
if has_flags avx512f avx512bw avx512cd avx512dq avx512vl; then level=4
elif has_flags avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; then level=3
elif has_flags cx16 lahf popcnt sse4_1 sse4_2 ssse3; then level=2
elif has_flags lm cmov cx8 fpu fxsr mmx syscall sse2; then level=1
else echo -e "${RED}无法确定 CPU 指令集级别。${NC}" >&2; exit 1; fi
case "$level" in
1) pkg=linux-xanmod-lts-x64v1;; 2) pkg=linux-xanmod-lts-x64v2;; 3) pkg=linux-xanmod-lts-x64v3;; 4) pkg=linux-xanmod-lts-x64v4;; esac
apt-get install -y "$pkg"
echo -e "${GREEN}$pkg 安装完成。请确认默认启动项后再重启系统。${NC}"
