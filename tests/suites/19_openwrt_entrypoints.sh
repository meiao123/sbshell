#!/usr/bin/env bash
# 19_openwrt_entrypoints.sh —— 批次 3 补：OpenWrt 未覆盖入口的行为测试。
#
# 此前这些入口只有静态 grep 断言（只要字面量还在文件里就算通过），但它们承载着几条
# 真机修过的关键行为：
#   * manage_autostart.sh apply_firewall 必须在交互 read **之前** 处理（否则开机/参数调用会卡在输入上，
#     重启后 nft 规则不会恢复 —— 代理静默失效）；
#   * switch_mode.sh 写新模式后若旧模式防火墙状态清不掉，必须**恢复旧模式**（否则 mode.conf 与
#     实际 nft 状态不一致）；
#   * 这几个脚本都用 `2> >(sed …)` 过滤 ubus 噪音：只要有孙进程继承管道写端，用管道喂 stdin
#     或 `$( )` 捕获输出就会挂住整个作业，所以统一用文件 stdin + `timeout -k`。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SCRIPTS=/etc/sing-box/scripts

# 统一的运行器：stdin 走文件（避免进程替换等待），硬上限 20s，附带可选环境变量。
run_owrt() {
    local script="$1" input="$2"
    shift 2
    printf '%b' "$input" > /tmp/s19.in
    local rc=0
    env "$@" timeout -k 5 20 bash "$script" < /tmp/s19.in > /tmp/s19.out 2>&1 || rc=$?
    return "$rc"
}

setup_owrt() {
    reset_stub_state
    reset_singbox_dir
    reset_openwrt_dirs
    install_repo_scripts openwrt
    fixture_write template.json "$VALID_CLIENT_CONFIG"
    # init 脚本是 `#!/bin/sh /etc/rc.common`；容器里若没有就用仓库自带的那份，
    # 否则 enable/enable 的 rc.d 行为无从验证（run.sh --local 也做同样的事）。
    [ -f /etc/rc.common ] || install -m 0755 "$SBSHELL_TEST_ROOT/rc.common" /etc/rc.common
}

# ------------------------------------------- manage_autostart.sh apply_firewall
suite_begin "manage_autostart: apply_firewall 不需要任何交互（P0-4 回归）"

setup_owrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
run_owrt "$SCRIPTS/manage_autostart.sh" '' apply_firewall; rc=$?
assert_rc "$rc" 0 "带 apply_firewall 参数时不需要交互即可完成"
assert_not_rc "$rc" 124 "apply_firewall 没有卡在输入上（未被超时杀掉）"
if nft_table_exists sing-box; then pass "TProxy 模式应用了 inet sing-box 表"; else fail "未应用 TProxy 表"; fi
assert_file /etc/sing-box/tproxy.state "写入 tproxy.state"

setup_owrt
printf 'MODE=TUN\n' > /etc/sing-box/mode.conf
run_owrt "$SCRIPTS/manage_autostart.sh" '' apply_firewall; rc=$?
assert_rc "$rc" 0 "TUN 模式下 apply_firewall 成功"
if nft_table_exists sing-box-tun; then pass "TUN 模式应用了 inet sing-box-tun 表"; else fail "未应用 TUN 表"; fi

setup_owrt
run_owrt "$SCRIPTS/manage_autostart.sh" '' apply_firewall; rc=$?
assert_not_rc "$rc" 0 "mode.conf 缺失时 apply_firewall 以非 0 结束"
assert_contains "$(cat /tmp/s19.out)" "无效的模式" "提示模式无效"

# ------------------------------------------------ manage_autostart.sh 启用/禁用
suite_begin "manage_autostart: 启用时写 init 脚本并在服务已运行时跳过重载"

setup_owrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
: > "$SBSHELL_STUB_STATE/singbox_active"
run_owrt "$SCRIPTS/manage_autostart.sh" '1\n'; rc=$?
out=$(cat /tmp/s19.out)
assert_rc "$rc" 0 "选择 1 启用自启动成功"
assert_file /etc/init.d/sbshell-firewall "写出开机防火墙 init 脚本"
assert_grep 'START=40' /etc/init.d/sbshell-firewall "init 脚本 START=40（在 sing-box 之前）"
assert_grep 'apply_firewall' /etc/init.d/sbshell-firewall "init 脚本回调 apply_firewall"
assert_file /etc/rc.d/S40sbshell-firewall "注册开机防火墙脚本"
assert_file /etc/rc.d/S99sing-box "注册 sing-box 自启动"
assert_contains "$out" "跳过当前防火墙重载" "服务已在运行时跳过防火墙重载（避免把运行中的表当外部表）"
assert_contains "$out" "自启动已成功启用" "给出启用成功提示"

suite_begin "manage_autostart: 服务未运行时会先下发当前模式的规则"

setup_owrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
run_owrt "$SCRIPTS/manage_autostart.sh" '1\n'; rc=$?
assert_rc "$rc" 0 "服务未运行时启用自启动成功"
if nft_table_exists sing-box; then pass "启用过程中下发了 TProxy 规则"; else fail "未下发 TProxy 规则"; fi

suite_begin "manage_autostart: 已启用时重复启用是幂等的"

setup_owrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
run_owrt "$SCRIPTS/manage_autostart.sh" '1\n'
run_owrt "$SCRIPTS/manage_autostart.sh" '1\n'; rc=$?
assert_rc "$rc" 0 "重复启用返回 0"
assert_contains "$(cat /tmp/s19.out)" "自启动已经开启" "重复启用提示无需操作"

# ------------------------------------------------------------- switch_mode.sh
suite_begin "switch_mode: mode.conf 不是普通文件时拒绝修改"

setup_owrt
rm -f /etc/sing-box/mode.conf
mkdir -p /etc/sing-box/mode.conf
run_owrt "$SCRIPTS/switch_mode.sh" '1\n'; rc=$?
assert_not_rc "$rc" 0 "mode.conf 是目录时拒绝执行"
assert_contains "$(cat /tmp/s19.out)" "不是普通文件" "说明拒绝原因"

suite_begin "switch_mode: 选择当前模式时不做任何改动"

setup_owrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
run_owrt "$SCRIPTS/switch_mode.sh" '1\n'; rc=$?
assert_rc "$rc" 0 "选择当前模式返回 0"
assert_contains "$(cat /tmp/s19.out)" "无需切换" "提示无需切换"
assert_no_file /etc/sing-box/tun.state "没有触碰 TUN 状态"

suite_begin "switch_mode: 旧模式状态清理失败时必须恢复原模式（F 系列回归）"

setup_owrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
printf 'OWNER=sbshell\nMODE=TProxy\n' > /etc/sing-box/tproxy.state
printf '' > "$SBSHELL_STUB_STATE/nft/inet__sing-box"
run_owrt "$SCRIPTS/switch_mode.sh" '2\n' SBSHELL_NFT_DELETE_FAIL=sing-box; rc=$?
assert_not_rc "$rc" 0 "清理失败时以非 0 退出"
assert_not_rc "$rc" 124 "清理失败路径没有挂住（未被超时杀掉）"
assert_contains "$(cat /tmp/s19.out)" "无法安全清理" "说明清理失败"
assert_eq "$(sed -n 's/^MODE=//p' /etc/sing-box/mode.conf)" "TProxy" "mode.conf 已恢复为原模式"

suite_begin "switch_mode: 正常切换写入新模式并清掉旧模式状态"

setup_owrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
printf 'OWNER=sbshell\nMODE=TProxy\n' > /etc/sing-box/tproxy.state
printf '' > "$SBSHELL_STUB_STATE/nft/inet__sing-box"
run_owrt "$SCRIPTS/switch_mode.sh" '2\n'; rc=$?
assert_rc "$rc" 0 "正常切换到 TUN 成功"
assert_eq "$(sed -n 's/^MODE=//p' /etc/sing-box/mode.conf)" "TUN" "mode.conf 写入新模式"
assert_no_file /etc/sing-box/tproxy.state "旧模式状态已清理"
if nft_table_exists sing-box; then fail "旧 TProxy 表应被删除"; else pass "旧 TProxy 表已删除"; fi

# ------------------------------------------------------- start/stop_singbox.sh
suite_begin "start_singbox: 已在运行/未知模式/正常启动"

setup_owrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
: > "$SBSHELL_STUB_STATE/singbox_active"
run_owrt "$SCRIPTS/start_singbox.sh" ''; rc=$?
assert_rc "$rc" 0 "已在运行时直接返回 0"
assert_contains "$(cat /tmp/s19.out)" "已在运行" "提示无需重复启动"

setup_owrt
printf 'MODE=Bogus\n' > /etc/sing-box/mode.conf
run_owrt "$SCRIPTS/start_singbox.sh" ''; rc=$?
assert_not_rc "$rc" 0 "未知模式时以非 0 退出"
assert_contains "$(cat /tmp/s19.out)" "未知代理模式" "提示未知模式"

setup_owrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
run_owrt "$SCRIPTS/start_singbox.sh" ''; rc=$?
assert_rc "$rc" 0 "TProxy 模式下启动成功"
if nft_table_exists sing-box; then pass "启动前下发了 TProxy 规则"; else fail "未下发 TProxy 规则"; fi
assert_contains "$(cat /tmp/s19.out)" "启动成功" "给出启动成功提示"

setup_owrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
printf '#!/bin/sh\nexit 1\n' > /etc/init.d/sing-box
chmod 0755 /etc/init.d/sing-box
run_owrt "$SCRIPTS/start_singbox.sh" ''; rc=$?
assert_not_rc "$rc" 0 "init 启动失败时以非 0 退出"
assert_contains "$(cat /tmp/s19.out)" "启动失败" "提示启动失败"

suite_begin "stop_singbox: 取消/未运行/停止失败/停止并清理"

setup_owrt
run_owrt "$SCRIPTS/stop_singbox.sh" 'n\n'; rc=$?
assert_rc "$rc" 0 "回答 n 时返回 0"
assert_contains "$(cat /tmp/s19.out)" "已取消" "提示已取消"

setup_owrt
run_owrt "$SCRIPTS/stop_singbox.sh" 'y\n'; rc=$?
assert_rc "$rc" 0 "未运行时返回 0"
assert_contains "$(cat /tmp/s19.out)" "无需重复停止" "提示无需重复停止"

setup_owrt
: > "$SBSHELL_STUB_STATE/singbox_active"
printf '#!/bin/sh\nexit 1\n' > /etc/init.d/sing-box
chmod 0755 /etc/init.d/sing-box
run_owrt "$SCRIPTS/stop_singbox.sh" 'y\n'; rc=$?
assert_not_rc "$rc" 0 "停止失败时以非 0 退出"
assert_contains "$(cat /tmp/s19.out)" "停止 sing-box 失败" "提示停止失败"

setup_owrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
printf 'OWNER=sbshell\nMODE=TProxy\n' > /etc/sing-box/tproxy.state
printf '' > "$SBSHELL_STUB_STATE/nft/inet__sing-box"
: > "$SBSHELL_STUB_STATE/singbox_active"
run_owrt "$SCRIPTS/stop_singbox.sh" 'y\ny\n'; rc=$?
assert_rc "$rc" 0 "停止并清理成功"
if nft_table_exists sing-box; then fail "选择清理后 TProxy 表应被删除"; else pass "选择清理后 TProxy 表已删除"; fi
assert_no_file /etc/sing-box/tproxy.state "选择清理后 state 已删除"

# ----------------------------------------------------------- check_config.sh
suite_begin "check_config: 缺 sing-box / 配置缺失 / 配置合法或非法"

setup_owrt
PATH=/usr/bin:/bin run_owrt "$SCRIPTS/check_config.sh" ''; rc=$?
assert_not_rc "$rc" 0 "找不到 sing-box 时以非 0 退出"

reset_stub_state
rm -rf /etc/sing-box
mkdir -p /etc/sing-box
run_owrt "$SCRIPTS/check_config.sh" ''; rc=$?
assert_not_rc "$rc" 0 "配置文件缺失时以非 0 退出"
assert_contains "$(cat /tmp/s19.out)" "配置文件不存在或为空" "提示配置文件缺失"

setup_owrt
printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json
run_owrt "$SCRIPTS/check_config.sh" ''; rc=$?
assert_rc "$rc" 0 "合法配置校验通过"
assert_contains "$(cat /tmp/s19.out)" "配置文件验证通过" "给出验证通过提示"

printf '%s\n' '{"log":{"level":"warn"},' > /etc/sing-box/config.json
run_owrt "$SCRIPTS/check_config.sh" ''; rc=$?
assert_not_rc "$rc" 0 "非法配置以非 0 退出"
assert_contains "$(cat /tmp/s19.out)" "配置文件验证失败" "提示验证失败"

suite_end
