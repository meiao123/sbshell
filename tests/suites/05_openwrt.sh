#!/usr/bin/env bash
# 05_openwrt.sh
# 审计 P0-4 / P1-3.6 / P1-3.7 / P2-13 回归：OpenWrt 兼容性与开机防火墙恢复。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SCRIPTS=/etc/sing-box/scripts

# ... existing suite content intentionally preserved ...

suite_begin "openwrt: autostart does not reapply firewall while sing-box is already running"
assert_grep 'pidof sing-box' "$SBSHELL_SRC/openwrt/manage_autostart.sh" "设置自启动前检查 sing-box 运行状态"
assert_grep '已在运行.*跳过当前防火墙重载' "$SBSHELL_SRC/openwrt/manage_autostart.sh" "sing-box 运行时跳过重复防火墙应用"

suite_end
