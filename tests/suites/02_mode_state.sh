#!/usr/bin/env bash
# 02_mode_state.sh
# 审计 P1-3.1 / P1-3.4 / P1-3.5 / P2-7 回归：TProxy <-> TUN 防火墙状态机。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SCRIPTS=/etc/sing-box/scripts
setup_mode_case() { reset_stub_state; reset_singbox_dir; install_repo_scripts debian; }
set_mode() { printf 'MODE=%s\n' "$1" > /etc/sing-box/mode.conf; }

suite_begin "firewall state machine: TProxy apply / idempotency"
setup_mode_case
set_mode TProxy
run_with_timeout bash "$SCRIPTS/configure_tproxy.sh" >/tmp/tproxy1.out 2>&1
rc=$?
assert_rc "$rc" 0 "首次应用 TProxy 规则成功"
if nft_table_exists sing-box; then pass "创建 inet sing-box 表"; else fail "未创建 inet sing-box 表"; fi
if ip_rules | grep -q "fwmark 0x1 lookup 100"; then pass "创建 mark-1 策略路由"; else fail "缺少 mark-1 策略路由"; fi
if ip_route_table 100 | grep -q "local default dev eth0"; then pass "创建 table 100 本地默认路由"; else fail "缺少 table 100 路由"; fi
assert_grep "^OWNER=sbshell" /etc/sing-box/tproxy.state "state 文件记录所有权"
assert_grep "^RULE_CREATED=1" /etc/sing-box/tproxy.state "RULE_CREATED=1"
assert_grep "^RULE_OWNED=1" /etc/sing-box/tproxy.state "RULE_OWNED=1"
assert_grep "^ROUTE_OWNED=1" /etc/sing-box/tproxy.state "ROUTE_OWNED=1"

run_with_timeout bash "$SCRIPTS/configure_tproxy.sh" >/tmp/tproxy2.out 2>&1
rc=$?
assert_rc "$rc" 0 "重复应用 TProxy 幂等"
assert_eq "$(ip_rules | grep -c 'fwmark 0x1 lookup 100')" "1" "策略路由没有重复添加"
assert_grep "^RULE_CREATED=0" /etc/sing-box/tproxy.state "已存在时 RULE_CREATED=0"
assert_grep "^RULE_OWNED=1" /etc/sing-box/tproxy.state "重复应用仍保留 RULE_OWNED=1"
assert_grep "^ROUTE_OWNED=1" /etc/sing-box/tproxy.state "重复应用仍保留 ROUTE_OWNED=1"

suite_begin "firewall state machine: TProxy -> TUN cleans tproxy state (P1-3.1)"
set_mode TUN
run_with_timeout bash "$SCRIPTS/configure_tun.sh" >/tmp/tun1.out 2>&1
rc=$?
assert_rc "$rc" 0 "应用 TUN 规则成功"
if nft_table_exists sing-box; then fail "TProxy 表应被删除"; else pass "TProxy 表已删除"; fi
if nft_table_exists sing-box-tun; then pass "创建 inet sing-box-tun 表"; else fail "未创建 TUN 表"; fi
assert_no_file /etc/sing-box/tproxy.state "tproxy.state 已清理"
if ip_rules | grep -q "fwmark 0x1 lookup 100"; then fail "策略路由应被删除"; else pass "策略路由已删除"; fi
if ip_route_table 100 | grep -q "local default"; then fail "table 100 路由应被删除"; else pass "table 100 路由已删除"; fi
assert_file /etc/sing-box/tun.state "写入 tun.state"
assert_grep "^OWNER=sbshell" /etc/sing-box/tun.state "tun.state 记录所有权"
assert_file /etc/sing-box/tun/nftables.conf "写出 tun/nftables.conf"
assert_no_grep "chain input" /etc/sing-box/tun/nftables.conf "TUN 表已收窄（不再创建 input 基链）"
assert_no_grep "chain output" /etc/sing-box/tun/nftables.conf "TUN 表已收窄（不再创建 output 基链）"
assert_grep "chain forward" /etc/sing-box/tun/nftables.conf "保留 forward 链"

suite_begin "firewall state machine: TUN -> TProxy cleans TUN state (P1-3.1)"
set_mode TProxy
run_with_timeout bash "$SCRIPTS/configure_tproxy.sh" >/tmp/tproxy3.out 2>&1
rc=$?
assert_rc "$rc" 0 "切回 TProxy 成功"
if nft_table_exists sing-box-tun; then fail "切回 TProxy 后 TUN 表应被删除（旧 Debian 脚本会残留）"; else pass "TUN 表已删除"; fi
assert_no_file /etc/sing-box/tun.state "tun.state 已清理"
assert_no_file /etc/sing-box/tun/nftables.conf "tun/nftables.conf 已清理"
if nft_table_exists sing-box; then pass "TProxy 表重新建立"; else fail "TProxy 表缺失"; fi

suite_begin "firewall state machine: foreign table must be refused, no partial state"
setup_mode_case
printf 'table inet sing-box {\n chain foreign { type filter hook input priority 0; policy accept; }\n}\n' > /tmp/foreign.nft
nft -f /tmp/foreign.nft
set_mode TProxy
run_with_timeout bash "$SCRIPTS/configure_tproxy.sh" >/tmp/foreign.out 2>&1
rc=$?
assert_not_rc "$rc" 0 "遇到非 Sbshell 管理的表时拒绝执行"
assert_grep "拒绝覆盖" /tmp/foreign.out "给出明确的拒绝原因"
if nft_table_exists sing-box; then pass "外来表未被删除"; else fail "外来表被误删"; fi
if ip_rules | grep -q "fwmark 0x1 lookup 100"; then fail "失败后未回滚策略路由"; else pass "失败后已回滚策略路由"; fi

suite_begin "firewall state machine: precise fwmark matching (P1-3.4)"
setup_mode_case
printf '9000:\tfrom all fwmark 0x10 lookup 100\n' > "$SBSHELL_STUB_STATE/ip_rules"
set_mode TProxy
run_with_timeout bash "$SCRIPTS/configure_tproxy.sh" >/tmp/fwmark.out 2>&1
rc=$?
assert_rc "$rc" 0 "存在 fwmark 0x10 规则时仍能应用"
if ip_rules | grep -q "fwmark 0x1 lookup 100"; then pass "正确创建 mark-1 策略路由"; else fail "被 fwmark 0x10 误导，未创建 mark-1 规则"; fi
assert_grep "^RULE_CREATED=1" /etc/sing-box/tproxy.state "state 记录 RULE_CREATED=1"
assert_grep "^RULE_OWNED=1" /etc/sing-box/tproxy.state "新建规则记录 ownership"

suite_begin "firewall state machine: nft failure rolls back to previous mode"
setup_mode_case
set_mode TUN
run_with_timeout bash "$SCRIPTS/configure_tun.sh" >/dev/null 2>&1
set_mode TProxy
SBSHELL_NFT_FAIL=sing-box run_with_timeout bash "$SCRIPTS/configure_tproxy.sh" >/tmp/rollback.out 2>&1
rc=$?
assert_not_rc "$rc" 0 "应用 TProxy 失败时以非 0 退出"
if nft_table_exists sing-box-tun; then pass "TUN 表已回滚恢复"; else fail "TUN 表未恢复"; fi
if nft_table_exists sing-box; then fail "失败的 TProxy 表不应残留"; else pass "没有残留的 TProxy 表"; fi
assert_file /etc/sing-box/tun.state "tun.state 已回滚恢复"

suite_end
