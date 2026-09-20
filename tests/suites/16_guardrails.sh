#!/usr/bin/env bash
# 16_guardrails.sh —— 批次 3：测试体系**自身**的护栏（防止假绿 / 提高可诊断性）。
#
# 被断言的护栏：
#   a) all.sh 收集不到套件时必须失败（旧实现打印"全部通过"并 exit 0）
#   b) 套件忘了 suite_end（没有小结行）或有 FAIL 行时，all.sh 必须判失败
#   c) assert_contains/assert_not_contains 失败信息里要带实际输出
#   d) nft 桩必须拒绝空规则集、不存在的文件、未知动词（旧桩一律成功）
#   e) run.sh --local 补齐 /etc/rc.common，且 host_guard 把它纳入备份/恢复
#   f) 07_no_install.sh 不再用 || true 吞掉 auto_update.sh 的退出码
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

REAL_ALL="$SBSHELL_TEST_ROOT/all.sh"

# ---------------------------------------------------------------- a) 空套件集
suite_begin "guardrail: all.sh 拒绝空套件集"
empty=$(mktemp -d)
mkdir -p "$empty/suites"
out=$(run_with_timeout env SBSHELL_TEST_ROOT="$empty" SBSHELL_SRC="$SBSHELL_SRC" \
    bash "$REAL_ALL" 2>&1)
rc=$?
assert_not_rc "$rc" 0 "没有收集到套件时 all.sh 必须失败"
assert_not_contains "$out" "全部行为测试套件通过" "空套件集下不得报成功"
rm -rf "$empty"

# ------------------------------------------------- b) 忘记 suite_end 的套件
suite_begin "guardrail: 忘记 suite_end 的套件必须被判失败"
bogus=$(mktemp -d)
mkdir -p "$bogus/suites"
cp -a "$SBSHELL_TEST_ROOT/lib" "$bogus/lib"
cat > "$bogus/suites/99_bogus.sh" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
. "$SBSHELL_TEST_ROOT/lib/harness.sh"
suite_begin "故意忘记 suite_end 的套件"
fail "这条断言不应被忽略"
exit 0
EOS
out=$(run_with_timeout env SBSHELL_TEST_ROOT="$bogus" SBSHELL_SRC="$SBSHELL_SRC" \
    bash "$REAL_ALL" 2>&1)
rc=$?
assert_not_rc "$rc" 0 "有 FAIL 行却没有小结行时 all.sh 必须失败"
assert_contains "$out" "没有输出小结行" "失败原因要指出缺少小结行"
assert_contains "$out" "99_bogus.sh" "失败原因要指出具体套件"
rm -rf "$bogus"

# ------------------------------------------------------- c) 断言可诊断性
suite_begin "guardrail: 断言失败要带实际输出"
diag=$(bash -c '. "$1/lib/harness.sh"; assert_contains "actual-value-42" "expected-fragment" "诊断用"' _ "$SBSHELL_TEST_ROOT" 2>&1)
assert_contains "$diag" "actual-value-42" "失败信息里包含实际输出"
diag2=$(bash -c '. "$1/lib/harness.sh"; assert_not_contains "present-value-7" "present-value-7" "诊断用"' _ "$SBSHELL_TEST_ROOT" 2>&1)
assert_contains "$diag2" "present-value-7" "not_contains 失败也带实际输出"

# ------------------------------------------------------------ d) nft 桩保真度
suite_begin "guardrail: nft 桩拒绝空规则集/缺失文件/未知动词"

printf '' > /tmp/g16-empty.nft
run_with_timeout nft -c -f /tmp/g16-empty.nft > /tmp/g16-a.out 2>&1
assert_not_rc "$?" 0 "空规则集必须被 -c 拒绝"

rm -f /tmp/g16-missing.nft
run_with_timeout nft -c -f /tmp/g16-missing.nft > /tmp/g16-b.out 2>&1
assert_not_rc "$?" 0 "不存在的规则集文件必须被 -c 拒绝"

printf 'table inet g16 {\n    chain c {\n        counter\n    }\n}\n' > /tmp/g16-ok.nft
run_with_timeout nft -c -f /tmp/g16-ok.nft > /tmp/g16-c.out 2>&1
assert_rc "$?" 0 "合法规则集仍然通过语法检查"

printf 'add rule inet g16 c counter\n' > /tmp/g16-notable.nft
run_with_timeout nft -f /tmp/g16-notable.nft > /tmp/g16-d.out 2>&1
assert_not_rc "$?" 0 "没有 table 声明的规则集必须被 -f 拒绝"

run_with_timeout nft frobnicate inet g16 > /tmp/g16-e.out 2>&1
assert_not_rc "$?" 0 "未支持的动词必须失败（旧桩静默 exit 0）"

# ------------------------------- e) /etc/rc.common 与 f) 退出码不再被吞掉
suite_begin "guardrail: --local 的 rc.common 与 auto_update 退出码"

assert_grep '/etc/rc.common' "$SBSHELL_SRC/tests/lib/host_guard.sh" \
    "host_guard 备份/恢复清单包含 /etc/rc.common"
assert_grep 'install -m 0755 "\$REPO/tests/rc.common" /etc/rc.common' "$SBSHELL_SRC/tests/run.sh" \
    "run.sh --local 会补齐 /etc/rc.common"
assert_no_grep 'auto_update.sh" > /tmp/no-install-au.out 2>&1 || true' "$SBSHELL_SRC/tests/suites/07_no_install.sh" \
    "不再用 || true 吞掉 auto_update.sh 的退出码"
assert_grep 'assert_rc "\$au_rc" 0' "$SBSHELL_SRC/tests/suites/07_no_install.sh" \
    "改为断言 auto_update.sh 的退出码为 0"

suite_end
