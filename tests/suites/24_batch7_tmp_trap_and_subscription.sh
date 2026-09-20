#!/usr/bin/env bash
# 24_batch7_tmp_trap_and_subscription.sh —— 批次 7：A-18（临时文件与清理 trap 的顺序）
# 与 A-17（set_defaults.sh 与 manual_input.sh 的订阅地址校验保持一致）。
#
# A-18 覆盖：
#   a) configure_tproxy.sh / update_scripts.sh：清理 trap 出现在第一个 mktemp **之前**
#      （反过来时中途失败会残留 /tmp，而 /tmp 是 tmpfs 即内存），且每个 mktemp 都有失败处理
#   b) update_ui.sh 的 cron 生成体：引用 $TMP 的 trap 一律 ${TMP:-} 保护
#      （acquire_lock 取锁超时 exit 1 时，trap 自己会在 set -u 下报 unbound）
#   c) 行为：抽出的 cleanup 在变量全空时不得报错（旧写法 rm -f "$TMP" 会 unbound）
#   d) 行为：抽出的 cleanup 能真正删除已创建的临时文件
#
# A-17 覆盖：
#   e) 非法订阅地址（空白 / # / &file= / 多行）必须被拒绝，且 defaults.conf 保持原样
#      （printf 不做转义，含换行的粘贴会插出额外的 KEY=value 行 = 注入任意默认键）
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SRC="${SBSHELL_SRC:-/src}"

# ------------------------------------------------------------ A-18
suite_begin "A-18: 清理 trap 必须先于临时文件创建"

check_order() {
    local file="$1" trap_pat="$2" mktemp_pat="$3" label="$4" trap_line mktemp_line
    trap_line=$(grep -nE "$trap_pat" "$file" | head -n1 | cut -d: -f1)
    mktemp_line=$(grep -nE "$mktemp_pat" "$file" | head -n1 | cut -d: -f1)
    if [ -n "$trap_line" ] && [ -n "$mktemp_line" ] && [ "$trap_line" -lt "$mktemp_line" ]; then
        pass "$label：trap(L$trap_line) 先于首个 mktemp(L$mktemp_line)"
    else
        fail "$label：trap(L${trap_line:-无}) 未先于首个 mktemp(L${mktemp_line:-无})"
    fi
}
# 注意 mktemp 要匹配**本处**的模板：这两个文件里还有下载/解包用的其它 mktemp。
check_order "$SRC/openwrt/configure_tproxy.sh" '^trap cleanup EXIT$' \
    'mktemp /tmp/sbshell-tproxy\.XXXXXX' "configure_tproxy.sh"
check_order "$SRC/openwrt/update_scripts.sh" "^trap 'release_scripts_lock; cleanup_update_tmp' EXIT$" \
    'mktemp -d /tmp/sbshell-update\.XXXXXX' "update_scripts.sh"

assert_no_grep 'mktemp /tmp/sbshell-tproxy\.XXXXXX$' "$SRC/openwrt/configure_tproxy.sh" \
    "configure_tproxy.sh 的 mktemp 都带失败处理"
assert_no_grep 'mktemp -d /tmp/sbshell-update\.XXXXXX$' "$SRC/openwrt/update_scripts.sh" \
    "update_scripts.sh 的 mktemp 都带失败处理"
assert_no_grep 'mktemp -d /tmp/sbshell-ui\.XXXXXX$' "$SRC/openwrt/update_ui.sh" \
    "update_ui.sh 的 mktemp 都带失败处理"

if grep -qF 'release_ui_lock; rm -rf "$TMP"' "$SRC/openwrt/update_ui.sh"; then
    fail "cron 版 trap 仍直接引用未赋值的 \$TMP"
else
    pass "cron 版 trap 不再直接引用未赋值的 \$TMP"
fi
if grep -qF '[ -z "${TMP:-}" ] || rm -rf "$TMP"' "$SRC/openwrt/update_ui.sh"; then
    pass "cron 版 trap 用 \${TMP:-} 保护"
else
    fail "cron 版 trap 缺少 \${TMP:-} 保护"
fi

suite_begin "A-18: cleanup 在变量全空/已赋值时的行为"

work=$(mktemp -d)
awk '/^cleanup\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$SRC/openwrt/configure_tproxy.sh" > "$work/cleanup.sh"
assert_file "$work/cleanup.sh" "成功抽出 configure_tproxy.sh 的 cleanup()"

out=$(env -u TMP -u OLD_TABLE -u OLD_TUN_TABLE -u OLD_TUN_STATE -u STATE_TMP \
    bash -c "set -u; . '$work/cleanup.sh'; cleanup; echo rc=\$?" 2>&1)
assert_contains "$out" "rc=0" "变量全空时 cleanup 正常返回（旧写法在 set -u 下 unbound 中止）"
assert_not_contains "$out" "unbound" "变量全空时 cleanup 不报 unbound"

touch "$work/t1" "$work/t2"
bash -c "set -u; . '$work/cleanup.sh'; TMP='$work/t1'; OLD_TABLE='$work/t2'; cleanup" >/dev/null 2>&1
if [ ! -e "$work/t1" ] && [ ! -e "$work/t2" ]; then
    pass "cleanup 删除了已创建的临时文件"
else
    fail "cleanup 未删除已创建的临时文件"
fi
rm -rf "$work"

# ------------------------------------------------------------ A-17
suite_begin "A-17: set_defaults.sh 拒绝非法订阅地址且不改写 defaults.conf"

set_defaults="$SRC/openwrt/set_defaults.sh"
defaults_file=/etc/sing-box/defaults.conf
mkdir -p /etc/sing-box
printf 'BACKEND_URL=\nSUBSCRIPTION_URL=https://old.example/sub\nTPROXY_TEMPLATE_URL=\nTUN_TEMPLATE_URL=\n' > "$defaults_file"
before=$(sha256sum "$defaults_file" | awk '{print $1}')

# 注意这是 BRE：括号不转义才是字面量（`\(` 在 BRE 里是分组，会假失败）。
assert_grep 'valid_subscription() {' "$set_defaults" "set_defaults.sh 带上与 manual_input.sh 相同的校验函数"

# 含空格的订阅地址（4 个 read：后端 / 订阅 / TProxy / TUN）
out=$(printf 'https://b.example/x\nhttps://s.example/a b\nhttps://t.example/t.json\nhttps://u.example/u.json\n' \
    | run_with_timeout bash "$set_defaults" 2>&1)
rc=$?
assert_not_rc "$rc" 0 "含空格的订阅地址被拒绝"
assert_contains "$out" "订阅地址包含非法字符" "给出明确原因"
assert_eq "$(sha256sum "$defaults_file" | awk '{print $1}')" "$before" "被拒绝时 defaults.conf 未被改写"

# '&file=' 与 '#' 同样必须被拒绝
for bad in 'https://s.example/a&file=/etc/passwd' 'https://s.example/a#frag'; do
    out=$(printf 'https://b.example/x\n%s\nhttps://t.example/t.json\nhttps://u.example/u.json\n' "$bad" \
        | run_with_timeout bash "$set_defaults" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] && case "$out" in *订阅地址包含非法字符*) true ;; *) false ;; esac; then
        pass "拒绝非法订阅地址：$bad"
    else
        fail "未拒绝非法订阅地址：$bad (rc=$rc)"
    fi
done

# 多行粘贴：不允许多出来的键落进 defaults.conf
printf 'https://b.example/x\nhttps://s.example/a\nMODE=evil\nhttps://t.example/t.json\n' \
    | run_with_timeout bash "$set_defaults" >/dev/null 2>&1
assert_no_grep '^MODE=' "$defaults_file" "多行输入不会注入额外的默认键"
assert_eq "$(sha256sum "$defaults_file" | awk '{print $1}')" "$before" "多行输入被拒绝后 defaults.conf 仍未被改写"

suite_end
