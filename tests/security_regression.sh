#!/bin/bash
set -Eeuo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

assert_absent() {
    local pattern="$1" file="$2" desc="$3"
    if grep -Eq "$pattern" "$file"; then
        fail "$desc"
    fi
    pass "$desc"
}

assert_present() {
    local pattern="$1" file="$2" desc="$3"
    grep -Eq "$pattern" "$file" || fail "$desc"
    pass "$desc"
}

assert_absent 'chmod[[:space:]]+777[[:space:]]+/etc/sing-box/mode\.conf' openwrt/switch_mode.sh 'mode.conf must not be world-writable'
assert_present 'chmod[[:space:]]+0644[[:space:]]+/etc/sing-box/mode\.conf|install .* -m 0644 .*mode\.conf' openwrt/switch_mode.sh 'OpenWrt mode.conf must have safe permissions'

assert_present 'mktemp -d' debian/check_update.sh 'Debian package switching must use an isolated temp directory'
assert_present 'dpkg -i[[:space:]]+"?\$[A-Za-z_]+/[^" ]+\.deb"?' debian/check_update.sh 'Debian package switching must install an explicit deb path'
assert_absent 'dpkg -i[[:space:]]+sing-box_\*\.deb|dpkg -i[[:space:]]+sing-box-beta_\*\.deb' debian/check_update.sh 'Debian package switching must not install wildcard debs'

assert_present 'nft list ruleset > "\$OLD"|nft list ruleset >\s*"\$OLD"' debian/configure_tun.sh 'Debian TUN must snapshot nftables before destructive changes'
assert_present 'ip -4 rule show' debian/configure_tun.sh 'Debian TUN must snapshot policy rules'
assert_present 'ip -4 route show table' debian/configure_tun.sh 'Debian TUN must snapshot policy routes'

assert_present 'nft list ruleset > "\$OLD"|nft list ruleset >\s*"\$OLD"' openwrt/configure_tun.sh 'OpenWrt TUN must snapshot nftables before changes'
assert_present 'ip -4 rule show' openwrt/configure_tun.sh 'OpenWrt TUN must inspect policy rules before cleanup'
assert_present 'ip -4 route show table' openwrt/configure_tun.sh 'OpenWrt TUN must inspect policy routes before cleanup'

assert_present 'BACKUP_MANUAL|backup_manual|manual\.conf.*backup' openwrt/manual_update.sh 'OpenWrt manual update must preserve manual.conf for rollback'
assert_present 'config\.json.*backup|BACKUP' openwrt/update_config.sh 'OpenWrt config update must preserve prior config for rollback'
assert_present 'config\.url.*backup|URL_BACKUP|backup.*config\.url' debian/update_config.sh 'Debian config URL must roll back with config.json'

assert_absent 'archive_top.*unzip' debian/update_ui.sh 'UI archive validation must not depend on post-extraction checks alone'
assert_present 'uncompressed|Uncompressed|unzip -Z1.*size|zipinfo' debian/update_ui.sh 'Debian UI updater must validate archive expansion size before extraction'
assert_present 'symbolic|symlink|hardlink|device' debian/update_ui.sh 'Debian UI updater must reject unsafe archive entry types'
assert_present 'uncompressed|Uncompressed|unzip -Z1.*size|zipinfo' openwrt/update_ui.sh 'OpenWrt UI updater must validate archive expansion size before extraction'
assert_present 'symbolic|symlink|hardlink|device' openwrt/update_ui.sh 'OpenWrt UI updater must reject unsafe archive entry types'

assert_absent 'raw\.githubusercontent\.com/.*/main/' debian/update_scripts.sh 'Debian self-update must not blindly trust mutable main branch'
assert_absent 'raw\.githubusercontent\.com/.*/main/' openwrt/update_scripts.sh 'OpenWrt self-update must not blindly trust mutable main branch'

assert_present 'stale|STALE|pidfile|PID|timeout' openwrt/manual_input.sh 'OpenWrt config lock must support stale-lock recovery'
assert_present 'stale|STALE|pidfile|PID|timeout' openwrt/manual_update.sh 'OpenWrt manual-update lock must support stale-lock recovery'
assert_present 'stale|STALE|pidfile|PID|timeout' openwrt/auto_update.sh 'OpenWrt auto-update lock must support stale-lock recovery'

assert_absent 'nft list ruleset > /etc/nftables\.conf' openwrt/configure_tun.sh 'OpenWrt TUN must not persist the entire live ruleset'
assert_absent 'nft list ruleset > /etc/nftables\.conf' debian/configure_tun.sh 'Debian TUN must not persist the entire live ruleset'

assert_present 'cat > /etc/init\.d/sing-box' openwrt/install_singbox.sh 'OpenWrt init integration must be explicit for review'
assert_present 'procd' openwrt/install_singbox.sh 'OpenWrt service integration must use procd'

pass 'all security regression assertions'
