#!/usr/bin/env bash
# 容器内总入口：依次运行所有行为测试套件并汇总结果。
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export SBSHELL_TEST_ROOT="${SBSHELL_TEST_ROOT:-$HERE}"
export SBSHELL_SRC="${SBSHELL_SRC:-/src}"
export SBSHELL_FAKEBIN="${SBSHELL_FAKEBIN:-$SBSHELL_TEST_ROOT/fakebin}"
export SBSHELL_FAKEBIN_BUSYBOX="${SBSHELL_FAKEBIN_BUSYBOX:-$SBSHELL_TEST_ROOT/fakebin-busybox}"
export SBSHELL_STUB_STATE="${SBSHELL_STUB_STATE:-/tmp/sbshell-stub-state}"
# 单个套件的硬上限：套件若卡在管道/网络/交互输入上，会被 kill 并**报告**，
# 而不是把整个作业拖到 job 级 timeout-minutes（那时被 kill 的是步骤本身，
# 注解与失败原因全都不会产出 —— 已经踩过一次）。
export SBSHELL_SUITE_TIMEOUT="${SBSHELL_SUITE_TIMEOUT:-600}"

# --local（宿主机直跑）时启用宿主机护栏：测试会删除/覆盖真实系统路径，
# 这里先整体备份，退出时恢复（容器里不启用，行为不变）。
if [ "${SBSHELL_LOCAL:-0}" = 1 ]; then
    # shellcheck source=tests/lib/host_guard.sh
    . "$SBSHELL_TEST_ROOT/lib/host_guard.sh"
    host_guard_init
    trap host_guard_restore EXIT
fi

[ "$(id -u)" -eq 0 ] || { echo "行为测试需要以 root 运行（容器内默认即 root）。" >&2; exit 1; }
[ -d "$SBSHELL_SRC" ] || { echo "找不到被测仓库: $SBSHELL_SRC" >&2; exit 1; }

run_suites=0
failed=0
for suite in "$SBSHELL_TEST_ROOT"/suites/*.sh; do
    [ -f "$suite" ] || continue
    run_suites=$((run_suites + 1))
    name=$(basename "$suite")
    printf '\n########## %s ##########\n' "$name"
    out=$(mktemp)
    rc=0
    env PATH="$SBSHELL_FAKEBIN:$PATH" timeout -k 5 "$SBSHELL_SUITE_TIMEOUT" bash "$suite" > "$out" 2>&1 || rc=$?
    cat "$out"
    # 只信"退出码 + 小结行 + FAIL 行"三者，缺一即判失败：
    # 套件若忘了调用 suite_end（或中途 exit），FAIL_COUNT 永远不会变成退出码，
    # 旧实现只看退出码就会把这种"断言失败但流程正常结束"的套件当成通过。
    summary=$(grep -E '^-- [0-9]+ checks, [0-9]+ failures$' "$out" | tail -n1)
    suite_failed=0
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        # 以 FAIL 行输出，CI 的注解收集才会把它带出来。
        echo "  FAIL 套件超时：${SBSHELL_SUITE_TIMEOUT}s 内没有结束（rc=$rc）。检查它是否卡在管道、网络或交互输入上。" >&2
        suite_failed=1
    fi
    if [ "$rc" -ne 0 ]; then
        echo "套件退出码非 0（rc=$rc）。" >&2
        suite_failed=1
    fi
    if [ -z "$summary" ]; then
        echo "套件没有输出小结行（-- N checks, M failures）：断言结果无法判定。" >&2
        suite_failed=1
    elif [ "${summary##*, }" != "0 failures" ]; then
        echo "套件小结报告失败：$summary" >&2
        suite_failed=1
    fi
    if grep -qE '^  FAIL ' "$out"; then
        echo "套件输出了 FAIL 断言（见上方日志）。" >&2
        suite_failed=1
    fi
    rm -f "$out"
    if [ "$suite_failed" -ne 0 ]; then
        failed=$((failed + 1))
        printf '########## %s FAILED ##########\n' "$name"
    fi
done

printf '\n=========================================\n'
if [ "$run_suites" -eq 0 ]; then
    echo "没有收集到任何测试套件（$SBSHELL_TEST_ROOT/suites/*.sh）。" >&2
    exit 1
fi
if [ "$failed" -eq 0 ]; then
    echo "全部行为测试套件通过（$run_suites 个套件）。"
    exit 0
fi
echo "$failed/$run_suites 个套件失败。"
exit 1
