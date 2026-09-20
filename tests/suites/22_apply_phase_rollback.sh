#!/usr/bin/env bash
# 22_apply_phase_rollback.sh —— 批次 5b：apply 阶段的未预期失败也必须回滚（A-10），
# 状态文件必须原子落盘（A-09）。
#
# A-10：`configure_tproxy.sh` 只装了 EXIT trap，而 `configure_tun.sh` 有
# `trap 'restore_prev || true' ERR`。仅有的回滚保护是几处**显式**的 `rollback; exit 1`；
# 只要失败发生在别处（例如 rule_pref_for_mark 里的 `ip -4 rule show` 失败），
# `set -Eeuo pipefail` 会直接中止 —— 此时 TUN 表已经被拆掉，留下半拆状态。
# 这里用 `SBSHELL_IP_FAIL_RULE_SHOW=1` 精确打在那个没有显式保护的点上。
#
# A-09：state 文件原本是 `cat > "$STATE_FILE"` 直写，掉电/中断会留下半写文件；
# 而 `clean_nft.sh` 必须看到 OWNER=sbshell 才肯删表 —— 半写的 state 会让表既不能重配
# 也不能清理。改为同目录 mktemp + `mv -f` 后，这里同时断言权限与无残留临时文件。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SCRIPTS=/etc/sing-box/scripts
DEFAULT_ROUTE='default via 192.0.2.1 dev eth0 proto static'

setup_case() {
    reset_stub_state
    reset_singbox_dir
    reset_openwrt_dirs
    install_repo_scripts openwrt
    printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
    # 已有一份 Sbshell 管理的 TUN 表与 state：TProxy 脚本会先拆掉它，之后才走到注入点，
    # 因此"表回来了"只可能来自 rollback。
    printf 'OWNER=sbshell\nMODE=TUN\nTUN_TABLE_CREATED=1\nINTERFACE=eth0\n' > /etc/sing-box/tun.state
    printf 'OWNER=sbshell\nMODE=TProxy\nTUN_TABLE_CREATED=0\nINTERFACE=eth0\nRULE_PREF=10010\nRULE_CREATED=1\nROUTE_CREATED=1\nRULE_OWNED=1\nROUTE_OWNED=1\n' > /etc/sing-box/tproxy.state
    printf 'table inet sing-box-tun {\n\tchain prerouting_tun {\n\t\ttype filter hook prerouting priority mangle; policy accept;\n\t}\n}\n' > "$SBSHELL_STUB_STATE/nft/inet__sing-box-tun"
    : > "$SBSHELL_STUB_STATE/nft/inet__sing-box"
}

run_tproxy() {
    local rc=0
    # 顺序很重要：run_with_timeout 是 shell 函数，**不能交给 env 去执行** —— env 找不到
    # 这个名字会直接以 127 退出，而下面"非 0 退出"的断言会把 127 当成注入生效（假绿）。
    run_with_timeout env SBSHELL_TEST_DEFAULT_ROUTE="$DEFAULT_ROUTE" "$@" \
        bash "$SCRIPTS/configure_tproxy.sh" > /tmp/s22.out 2>&1 || rc=$?
    return "$rc"
}

state_leftovers() {
    # 用 glob 而不是 `ls | grep`（SC2010）：文件名里可能有空格/特殊字符。
    local f
    for f in /etc/sing-box/.*.state.*; do
        [ -e "$f" ] || continue
        printf '%s\n' "${f##*/}"
    done
}

# ------------------------------- A-10：未预期失败不能留下半拆状态
suite_begin "apply 阶段未预期失败：不得留下半拆状态（A-10）"

# 注入 `ip rule show` 失败。注意这套脚本是 `set -eu` 且**没有 pipefail**，而 rule_pref_for_mark()
# 里取的是 `ip … | awk …` 中 awk 的状态，因此这个注入不保证让脚本失败（实测 rc=0）。所以这里断言
# 的是**不变式**：无论成败，都不允许出现「TUN 表已被拆掉、TProxy 表又没建起来」的半拆状态。
# `configure_tproxy.sh` 是否真的装了 ERR trap / INT TERM 由本套件末尾的静态断言保证。
setup_case
run_tproxy SBSHELL_IP_FAIL_RULE_SHOW=1; rc=$?
assert_not_rc "$rc" 127 "脚本确实被执行（127 = command not found，不是注入导致的失败）"
assert_not_rc "$rc" 124 "注入失败路径没有挂住（未被超时杀掉）"
if [ "$rc" -eq 0 ]; then
    if nft_table_exists sing-box; then pass "成功路径建立了 TProxy 表"; else fail "成功路径缺 TProxy 表"; fi
    if nft_table_exists sing-box-tun; then fail "成功路径下旧 TUN 表应已拆除"; else pass "成功路径下旧 TUN 表已拆除"; fi
    assert_grep '^OWNER=sbshell$' /etc/sing-box/tproxy.state "成功路径 state 与结果自洽"
else
    if nft_table_exists sing-box-tun; then pass "失败后 TUN 表已回滚恢复（不是半拆状态）"; else fail "失败后 TUN 表没有恢复：正是 A-10 的半拆状态"; fi
    if nft_table_exists sing-box; then fail "失败后不应留下新建的 TProxy 表"; else pass "失败后没有留下新建的 TProxy 表"; fi
fi

# ------------------------------- A-09：状态文件原子落盘
suite_begin "状态文件原子落盘：成功路径留下 0600 的 state 且无临时文件残留（A-09）"

setup_case
run_tproxy; rc=$?
assert_rc "$rc" 0 "正常应用 TProxy 返回 0"
assert_file /etc/sing-box/tproxy.state "state 文件存在"
assert_eq "$(stat -c '%a' /etc/sing-box/tproxy.state 2>/dev/null)" "600" "state 文件权限 0600"
assert_grep '^OWNER=sbshell$' /etc/sing-box/tproxy.state "state 里仍写明 OWNER=sbshell"
assert_eq "$(state_leftovers)" "" "成功路径不残留 .tproxy.state.* 临时文件"

# ------------------------------- 静态不变式：两个脚本的 trap 必须一致
suite_begin "防火墙脚本的 trap 必须一致（A-10 / A-22）"

assert_grep "trap 'rollback || true' ERR" "$SBSHELL_SRC/openwrt/configure_tproxy.sh" \
    "configure_tproxy.sh 有 ERR trap"
assert_grep "trap 'restore_prev || true' ERR" "$SBSHELL_SRC/openwrt/configure_tun.sh" \
    "configure_tun.sh 有 ERR trap"
assert_grep "INT TERM" "$SBSHELL_SRC/openwrt/configure_tproxy.sh" \
    "configure_tproxy.sh 处理 INT/TERM"
assert_grep "INT TERM" "$SBSHELL_SRC/openwrt/configure_tun.sh" \
    "configure_tun.sh 处理 INT/TERM"

suite_end
