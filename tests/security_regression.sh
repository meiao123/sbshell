#!/bin/bash
set -Eeuo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_absent() { local p="$1" f="$2" d="$3"; grep -Eq "$p" "$f" && fail "$d" || pass "$d"; }
assert_present() { local p="$1" f="$2" d="$3"; grep -Eq "$p" "$f" || fail "$d"; pass "$d"; }
assert_before() { local a="$1" b="$2" f="$3" d="$4"; awk -v a="$a" -v b="$b" 'BEGIN{fa=fb=0} index($0,a){fa=1} index($0,b)&&fa{fb=1} END{exit !(fa&&fb)}' "$f" || fail "$d"; pass "$d"; }

assert_absent 'chmod[[:space:]]+777[[:space:]]+/etc/sing-box/mode\.conf' openwrt/switch_mode.sh 'mode.conf must not be world-writable'
assert_present 'chmod[[:space:]]+0644[[:space:]]+"?\$MODE_FILE"?' openwrt/switch_mode.sh 'OpenWrt mode.conf must have safe permissions'
assert_present 'clean_nft\.sh' openwrt/switch_mode.sh 'OpenWrt mode switching must clean managed firewall state before applying a new mode'
assert_present 'BACKUP_MODE=' openwrt/switch_mode.sh 'OpenWrt mode switching must retain the previous mode for rollback'

assert_present 'mktemp -d' debian/check_update.sh 'Debian package switching must use an isolated temp directory'
assert_absent 'dpkg -i[[:space:]]+sing-box_\*\.deb|dpkg -i[[:space:]]+sing-box-beta_\*\.deb' debian/check_update.sh 'Debian package switching must not install wildcard debs'
assert_before 'cd "$TMP_DIR"' 'apt-get download' debian/check_update.sh 'Debian package download must happen inside the private temp directory'
assert_present 'apt-get install -y "\$\{debs\[0\]\}"' debian/check_update.sh 'Debian package switching must use transactional apt installation'

assert_present 'OLD_TABLE=' debian/configure_tun.sh 'Debian TUN must snapshot only owned firewall state before changes'
assert_present 'ip -4 rule show > "$OLD_RULE"' debian/configure_tun.sh 'Debian TUN must snapshot policy rules'
assert_present 'ip -4 route show table' debian/configure_tun.sh 'Debian TUN must snapshot policy routes'
assert_present 'OLD_TUN_TABLE=' openwrt/configure_tun.sh 'OpenWrt TUN must snapshot its owned table before reapplication'
assert_present 'TUN_STATE_FILE=' openwrt/configure_tun.sh 'OpenWrt TUN must have a dedicated ownership state file'
assert_present 'OWNER=sbshell' openwrt/configure_tun.sh 'OpenWrt TUN must record Sbshell ownership'
assert_present 'nft delete table inet sing-box-tun' openwrt/configure_tun.sh 'OpenWrt TUN must delete its owned table before idempotent reapplication'
assert_present 'OLD_TPROXY_TABLE=' openwrt/configure_tun.sh 'OpenWrt TUN must snapshot the owned TProxy table before cross-mode cleanup'
assert_present 'TPROXY_STATE_FILE=' openwrt/configure_tun.sh 'OpenWrt TUN must inspect TProxy ownership before removing it'
assert_absent 'nft list ruleset > /etc/nftables\.conf' openwrt/configure_tun.sh 'OpenWrt TUN must not persist the entire live ruleset'
assert_absent 'nft list ruleset > /etc/nftables\.conf' debian/configure_tun.sh 'Debian TUN must not persist the entire live ruleset'

assert_present 'rollback\(\)' debian/configure_tproxy.sh 'Debian TProxy must have an explicit rollback path'
assert_present 'rollback\(\)' openwrt/configure_tproxy.sh 'OpenWrt TProxy must have an explicit rollback path'
assert_present 'OWNER=sbshell' debian/configure_tproxy.sh 'Debian TProxy must track ownership of its policy state'
assert_present 'OWNER=sbshell' openwrt/configure_tproxy.sh 'OpenWrt TProxy must track ownership of its policy state'
assert_present 'OLD_TUN_TABLE=' openwrt/configure_tproxy.sh 'OpenWrt TProxy must snapshot the owned TUN table before cleanup'
assert_present 'TUN_STATE_FILE=' openwrt/configure_tproxy.sh 'OpenWrt TProxy must inspect TUN ownership before removing it'
assert_present 'nft delete table inet sing-box-tun' openwrt/configure_tproxy.sh 'OpenWrt TProxy must clean the owned TUN table'
assert_present 'rm -f "$TUN_STATE_FILE"' openwrt/configure_tproxy.sh 'OpenWrt TProxy must remove stale TUN ownership state after success'

assert_present 'clean_owned_table sing-box-tun' openwrt/clean_nft.sh 'OpenWrt cleanup must handle the TUN table'
assert_present 'clean_owned_table sing-box' openwrt/clean_nft.sh 'OpenWrt cleanup must handle the TProxy table'
assert_present 'OWNER=sbshell' openwrt/clean_nft.sh 'OpenWrt cleanup must require Sbshell ownership'
assert_absent 'nft flush ruleset' openwrt/clean_nft.sh 'OpenWrt cleanup must never flush the entire nftables ruleset'

assert_present 'manual\.backup' openwrt/manual_update.sh 'OpenWrt manual update must preserve manual.conf for rollback'
assert_present 'manual\.backup' debian/manual_update.sh 'Debian manual update must preserve manual.conf for rollback'
assert_present 'backup_url' debian/update_config.sh 'Debian config URL must roll back with config.json'

assert_present 'validate_archive' debian/update_ui.sh 'Debian UI updater must validate archive metadata before extraction'
assert_before 'validate_archive' 'unzip -q -o' debian/update_ui.sh 'Debian UI archive metadata validation must precede extraction'
assert_present 'case "\$mode" in l\*|b\*|c\*|p\*' debian/update_ui.sh 'Debian UI updater must reject symlink/device archive entries'
assert_present 'validate_archive' openwrt/update_ui.sh 'OpenWrt UI updater must validate archive metadata before extraction'
assert_before 'validate_archive' 'unzip -q -o' openwrt/update_ui.sh 'OpenWrt UI archive metadata validation must precede extraction'
assert_present 'case "\$mode" in l\*|b\*|c\*|p\*' openwrt/update_ui.sh 'OpenWrt UI updater must reject symlink/device archive entries'

assert_present 'BASE_REF=security-release-2026-09-11' debian/update_scripts.sh 'Debian self-update must use the reviewed security release branch'
assert_present 'BASE_REF=security-release-2026-09-11' openwrt/update_scripts.sh 'OpenWrt self-update must use the reviewed security release branch'
assert_present 'RELEASE_REF=security-release-2026-09-11' sbshall.sh 'Bootstrap must use the reviewed security release branch'
assert_present 'BASE_REF=security-release-2026-09-11' debian/menu.sh 'Debian menu must use the reviewed security release branch'
assert_present 'BASE_REF=security-release-2026-09-11' openwrt/menu.sh 'OpenWrt menu must use the reviewed security release branch'
assert_absent 'raw\.githubusercontent\.com/.*/main/' debian/update_scripts.sh 'Debian self-update must not trust mutable main branch'
assert_absent 'raw\.githubusercontent\.com/.*/main/' openwrt/update_scripts.sh 'OpenWrt self-update must not trust mutable main branch'
assert_absent 'raw\.githubusercontent\.com/.*/main/' sbshall.sh 'Bootstrap must not trust mutable main branch'

assert_present 'LOCK_TIMEOUT=' openwrt/manual_input.sh 'OpenWrt config lock must support stale-lock recovery'
assert_present 'LOCK_TIMEOUT=' openwrt/manual_update.sh 'OpenWrt manual-update lock must support stale-lock recovery'
assert_present 'LOCK_TIMEOUT=' openwrt/auto_update.sh 'OpenWrt auto-update lock must support stale-lock recovery'
assert_present 'LOCK_TIMEOUT=' openwrt/update_ui.sh 'OpenWrt UI lock must support stale-lock recovery'

assert_absent 'LOG_FILE="latency_log\.txt"' debian/delaytest.sh 'Latency log must not be relative to an attacker-controlled working directory'
assert_present 'LOG_FILE=/var/log/sbshell-latency\.log' debian/delaytest.sh 'Latency log must use a protected system path'
assert_present 'ACME_VERSION=3\.1\.5' debian/setup.sh 'Debian setup must pin the audited acme.sh release'
assert_present 'verify-tag' debian/setup.sh 'Debian setup must verify the acme.sh release signature'
assert_absent 'curl[^\n]*https://get\.acme\.sh[^\n]*\|[[:space:]]*sh' debian/setup.sh 'Debian setup must not pipe a remote installer into a shell'

assert_present 'if \[ ! -e /etc/init\.d/sing-box \]' openwrt/install_singbox.sh 'OpenWrt installer must not overwrite an existing init script'
assert_present 'procd' openwrt/install_singbox.sh 'OpenWrt service integration must use procd'

pass 'all security regression assertions'
