#!/usr/bin/env bash
# 05_openwrt.sh
# 审计 P0-4 / P1-3.6 / P1-3.7 / P2-13 回归：OpenWrt 兼容性与开机防火墙恢复。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SCRIPTS=/etc/sing-box/scripts

suite_begin "openwrt: busybox grep has no -P, scripts must not rely on it (P1-3.6)"

reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
cat > /etc/sing-box/defaults.conf <<'EOF'
TPROXY_TEMPLATE_URL=https://tpl.test/template.json
TUN_TEMPLATE_URL=https://tpl.test/template.json
EOF
fixture_write template.json "$VALID_CLIENT_CONFIG"

if grep -rn 'grep -oP' "$SBSHELL_SRC/openwrt" "$SBSHELL_SRC/debian" >/dev/null 2>&1; then
    fail "仍有脚本使用 grep -oP（busybox grep 不支持 PCRE）"
else
    pass "两平台脚本都没有使用 grep -oP"
fi

output=$(printf '\n\n\ny\n' | (
    export PATH="$SBSHELL_FAKEBIN_BUSYBOX:$PATH"
    run_with_timeout bash "$SCRIPTS/manual_input.sh"
) 2>&1)
rc=$?
assert_rc "$rc" 0 "在 busybox grep 环境下 manual_input.sh 成功"
assert_not_contains "$output" "未知的模式" "MODE 解析正确（旧代码 grep -oP 失败后会报未知模式）"
assert_file /etc/sing-box/config.json "配置已写入"

suite_begin "openwrt: initialize() must not swallow a failing step (P1-3.7)"

reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
for f in "$SBSHELL_SRC"/openwrt/*.sh; do cp "$f" "$SBSHELL_FIXTURES/"; done

output=$(printf '\n' | SBSHELL_OPKG_FAIL=1 run_with_timeout bash "$SCRIPTS/menu.sh" 2>&1)
rc=$?
assert_not_rc "$rc" 0 "安装失败时初始化以非 0 结束"
if [ -f /etc/sing-box/.initialized ]; then
    fail "安装失败却写入了 .initialized（旧代码 errexit 在函数内被关闭）"
else
    pass "失败时没有写入 .initialized"
fi

suite_begin "openwrt: autostart installs a boot-time firewall init script (P0-4)"

reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json

printf '1\n' | run_with_timeout bash "$SCRIPTS/manage_autostart.sh" >/tmp/autostart1.out 2>&1
rc=$?
assert_rc "$rc" 0 "启用自启动成功"
assert_file /etc/init.d/sbshell-firewall "生成 /etc/init.d/sbshell-firewall"
assert_grep 'apply_firewall' /etc/init.d/sbshell-firewall "开机脚本调用 apply_firewall"
assert_grep 'START=40' /etc/init.d/sbshell-firewall "开机脚本先于 sing-box (START=40)"
if [ -e /etc/rc.d/S40sbshell-firewall ]; then pass "已注册开机启动链接"; else fail "未注册开机启动链接"; fi
if nft_table_exists sing-box; then pass "启用时已下发防火墙规则"; else fail "启用时未下发规则"; fi

# 模拟重启：nftables 规则不落盘，规则丢失后由开机脚本恢复
rm -f "$SBSHELL_STUB_STATE/nft/inet__sing-box"
if nft_table_exists sing-box; then fail "模拟重启失败"; else pass "已模拟重启（规则丢失）"; fi
/etc/init.d/sbshell-firewall start >/tmp/autostart2.out 2>&1
assert_rc "$?" 0 "开机脚本执行成功"
if nft_table_exists sing-box; then pass "开机后规则被重新下发"; else fail "开机后规则仍未恢复"; fi

printf '2\n' | run_with_timeout bash "$SCRIPTS/manage_autostart.sh" >/tmp/autostart3.out 2>&1
assert_rc "$?" 0 "禁用自启动成功"
if [ -e /etc/rc.d/S40sbshell-firewall ]; then fail "开机启动链接未移除"; else pass "开机启动链接已移除"; fi

suite_begin "openwrt: TUN mode needs the tun module (P2-13)"

assert_grep 'kmod-tun' "$SBSHELL_SRC/openwrt/install_singbox.sh" "安装脚本尝试安装 kmod-tun"
assert_grep 'kmod-tun.*|| true' "$SBSHELL_SRC/openwrt/install_singbox.sh" "kmod-tun 安装失败不阻断"

suite_end
