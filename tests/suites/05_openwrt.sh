#!/usr/bin/env bash
# 05_openwrt.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

suite_begin "openwrt scripts keep config private"

assert_grep 'install -o root -g root -m 0600.*\$CONFIG_FILE' "$SBSHELL_SRC/openwrt/manual_update.sh" "OpenWrt manual_update 使用 0600 config.json"
assert_grep 'install -o root -g root -m 0600.*\$CONFIG_FILE' "$SBSHELL_SRC/openwrt/auto_update.sh" "OpenWrt auto_update 使用 0600 config.json"
assert_grep 'chmod 0600.*tmp_config' "$SBSHELL_SRC/openwrt/manual_input.sh" "OpenWrt manual_input 临时 config 使用 0600"
assert_grep 'release_lock' "$SBSHELL_SRC/openwrt/manual_input.sh" "OpenWrt manual_input 存在 ownership-safe lock release"
assert_grep 'release_lock' "$SBSHELL_SRC/openwrt/manual_update.sh" "OpenWrt manual_update 存在 ownership-safe lock release"
assert_grep 'update_scripts.sh' "$SBSHELL_SRC/openwrt/update_scripts.sh" "OpenWrt updater 能更新自身"
assert_grep 'update_scripts.sh' "$SBSHELL_SRC/openwrt/menu.sh" "OpenWrt menu 与 updater 保持脚本集合一致"

suite_end
