#!/usr/bin/env bash
# 容器内总入口：依次运行所有行为测试套件并汇总结果。
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export SBSHELL_TEST_ROOT="${SBSHELL_TEST_ROOT:-$HERE}"
export SBSHELL_SRC="${SBSHELL_SRC:-/src}"
export SBSHELL_FAKEBIN="${SBSHELL_FAKEBIN:-$SBSHELL_TEST_ROOT/fakebin}"
export SBSHELL_FAKEBIN_BUSYBOX="${SBSHELL_FAKEBIN_BUSYBOX:-$SBSHELL_TEST_ROOT/fakebin-busybox}"
export SBSHELL_STUB_STATE="${SBSHELL_STUB_STATE:-/tmp/sbshell-stub-state}"

[ "$(id -u)" -eq 0 ] || { echo "行为测试需要以 root 运行（容器内默认即 root）。" >&2; exit 1; }
[ -d "$SBSHELL_SRC" ] || { echo "找不到被测仓库: $SBSHELL_SRC" >&2; exit 1; }

failed=0
for suite in "$SBSHELL_TEST_ROOT"/suites/*.sh; do
    [ -f "$suite" ] || continue
    printf '\n########## %s ##########\n' "$(basename "$suite")"
    if ! env PATH="$SBSHELL_FAKEBIN:$PATH" bash "$suite"; then
        failed=$((failed + 1))
        printf '########## %s FAILED ##########\n' "$(basename "$suite")"
    fi
done

printf '\n=========================================\n'
if [ "$failed" -eq 0 ]; then
    echo "全部行为测试套件通过。"
    exit 0
fi
echo "$failed 个套件失败。"
exit 1
