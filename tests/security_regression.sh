#!/bin/bash
set -Eeuo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_absent() { local p="$1" f="$2" d="$3"; grep -Eq "$p" "$f" && fail "$d" || pass "$d"; }
assert_present() { local p="$1" f="$2" d="$3"; grep -Eq "$p" "$f" || fail "$d"; pass "$d"; }
assert_before() { local a="$1" b="$2" f="$3" d="$4"; awk -v a="$a" -v b="$b" 'BEGIN{fa=fb=0} index($0,a){fa=1} index($0,b)&&fa{fb=1} END{exit !(fa&&fb)}' "$f" || fail "$d"; pass "$d"; }

assert_absent 'chmod[[:space:]]+777[[:space:]]+/etc/sing-box/mode\.conf' openwrt/switch_mode.sh 'mode.conf must not be world-writable'
assert_present 'chmod[[:space:]]+0644[[:space:]]+"?\$MODE_FILE"?' openwrt/switch_mode.sh 'OpenWrt mode.conf must have safe permissions'

assert_present 'mktemp -d' debian/check_update.sh 'Debian package switching must use an isolated temp directory'
assert_absent 'dpkg -i[[:space:]]+sing-box_\*\.deb|dpkg -i[[:space:]]+sing-box-beta_\*\.deb' debian/check_update.sh 'Debian package switching must not install wildcard debs'
assert_before 'cd "$TMP_DIR"' 'apt-get download' debian/check_update.sh 'Debian package download must happen inside the private temp directory'
assert_present 'dpkg -i' debian/check_update.sh 'Debian package switching must install a concrete deb path'

assert_present 'OLD_NFT=' debian/configure_tun.sh 'Debian TUN must snapshot nftables before changes'
assert_present 'ip -4 rule show > "$OLD_RULE"' debian/configure_tun.sh 'Debian TUN must snapshot policy rules'
assert_present 'ip -4 route show table' debian/configure_tun.sh 'Debian TUN must snapshot policy routes'
assert_present 'OLD_NFT=' openwrt/configure_tun.sh 'OpenWrt TUN must snapshot nftables before changes'
assert_present 'ip -4 rule show > "$OLD_RULE"' openwrt/configure_tun.sh 'OpenWrt TUN must inspect policy rules before cleanup'
assert_present 'ip -4 route show table' openwrt/configure_tun.sh 'OpenWrt TUN must inspect policy routes before cleanup'

assert_present 'manual\.backup' openwrt/manual_update.sh 'OpenWrt manual update must preserve manual.conf for rollback'
assert_present 'manual\.backup' debian/manual_update.sh 'Debian manual update must preserve manual.conf for rollback'
assert_present 'backup_url' debian/update_config.sh 'Debian config URL must roll back with config.json'

assert_present 'validate_archive' debian/update_ui.sh 'Debian UI updater must validate archive metadata before extraction'
assert_before 'validate_archive' 'unzip -q -o' debian/update_ui.sh 'Debian UI archive metadata validation must precede extraction'
assert_present 'case "$mode" in l\*|b\*|c\*|p\*' debian/update_ui.sh 'Debian UI updater must reject symlink/device archive entries'
assert_present 'validate_archive' openwrt/update_ui.sh 'OpenWrt UI updater must validate archive metadata before extraction'
assert_before 'validate_archive' 'unzip -q -o' openwrt/update_ui.sh 'OpenWrt UI archive metadata validation must precede extraction'
assert_present 'case "$mode" in l\*|b\*|c\*|p\*' openwrt/update_ui.sh 'OpenWrt UI updater must reject symlink/device archive entries'

assert_present 'BASE_REF=' debian/update_scripts.sh 'Debian self-update must pin a repository commit'
assert_present 'BASE_REF=' openwrt/update_scripts.sh 'OpenWrt self-update must pin a repository commit'
assert_absent 'raw\.githubusercontent\.com/.*/main/' debian/update_scripts.sh 'Debian self-update must not trust mutable main branch'
assert_absent 'raw\.githubusercontent\.com/.*/main/' openwrt/update_scripts.sh 'OpenWrt self-update must not trust mutable main branch'

assert_present 'LOCK_TIMEOUT=' openwrt/manual_input.sh 'OpenWrt config lock must support stale-lock recovery'
assert_present 'LOCK_TIMEOUT=' openwrt/manual_update.sh 'OpenWrt manual-update lock must support stale-lock recovery'
assert_present 'LOCK_TIMEOUT=' openwrt/auto_update.sh 'OpenWrt auto-update lock must support stale-lock recovery'
assert_present 'LOCK_TIMEOUT=' openwrt/update_ui.sh 'OpenWrt UI lock must support stale-lock recovery'

assert_absent 'nft list ruleset > /etc/nftables\.conf' openwrt/configure_tun.sh 'OpenWrt TUN must not persist the entire live ruleset'
assert_absent 'nft list ruleset > /etc/nftables\.conf' debian/configure_tun.sh 'Debian TUN must not persist the entire live ruleset'

assert_absent 'curl[^\n]*https://get\.acme\.sh[^\n]*\|[[:space:]]*sh' debian/setup.sh 'Debian setup must not pipe a remote installer into a shell'
assert_present 'ACME_VERSION=3\.1\.5' debian/setup.sh 'Debian setup must pin the audited acme.sh release'
assert_present 'verify-tag' debian/setup.sh 'Debian setup must verify the acme.sh release signature'

assert_present 'if \[ ! -e /etc/init\.d/sing-box \]' openwrt/install_singbox.sh 'OpenWrt installer must not overwrite an existing init script'
assert_present 'procd' openwrt/install_singbox.sh 'OpenWrt service integration must use procd'

pass 'all security regression assertions'
