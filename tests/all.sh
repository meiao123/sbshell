#!/usr/bin/env bash
# 容器内总入口：依次运行所有行为测试套件并汇总结果。
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export SBSHELL_TEST_ROOT="${SBSHELL_TEST_ROOT:-$HERE}"
export SBSHELL_SRC="${SBSHELL_SRC:-/src}"
export SBSHELL_FAKEBIN="${SBSHELL_FAKEBIN:-$SBSHELL_TEST_ROOT/fakebin}"
export SBSHELL_FAKEBIN_BUSYBOX="${SBSHELL_FAKEBIN_BUSYBOX:-$SBSHELL_TEST_ROOT/fakebin-busybox}"
export SBSHELL_STUB_STATE="${SBSHELL_STUB_STATE:-/tmp/sbshell-stub-state}"

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
    env PATH="$SBSHELL_FAKEBIN:$PATH" bash "$suite" > "$out" 2>&1 || rc=$?
    cat "$out"
    # 只信"退出码 + 小结行 + FAIL 行"三者，缺一即判失败：
    # 套件若忘了调用 suite_end（或中途 exit），FAIL_COUNT 永远不会变成退出码，
    # 旧实现只看退出码就会把这种"断言失败但流程正常结束"的套件当成通过。
    summary=$(grep -E '^-- [0-9]+ checks, [0-9]+ failures$' "$out" | tail -n1)
    suite_failed=0
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
