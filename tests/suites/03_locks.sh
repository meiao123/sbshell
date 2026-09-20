#!/usr/bin/env bash
# 03_locks.sh
# 审计配置锁的获取、释放以及陈旧锁接管后的 ownership-safe 清理。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

suite_begin "openwrt auto-update lock is released and ownership-safe"
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
rm -rf /tmp/sbshell-config.lock

cat > /etc/sing-box/manual.conf <<'EOF'
BACKEND_URL=https://backend.test
SUBSCRIPTION_URL=tk?token=demo
TEMPLATE_URL=https://tpl.test/template.json
EOF
fixture_write template.json "$VALID_CLIENT_CONFIG"
printf '1\n12\n' | run_with_timeout bash /etc/sing-box/scripts/auto_update.sh >/tmp/auto1.out 2>&1
rc=$?
assert_rc "$rc" 0 "设置自动更新成功"
assert_file /etc/sing-box/update-singbox.sh "生成 update-singbox.sh"
assert_file /etc/crontabs/root "写入 /etc/crontabs/root"
assert_grep '\*/12 \* \* \*' /etc/crontabs/root "cron 表达式使用 */12"
assert_grep '\[ "\$owner" = "\$\$" \] && rm -rf "\$LOCK_DIR"' /etc/sing-box/update-singbox.sh "更新脚本只允许 owner 删除配置锁"

run_with_timeout /etc/sing-box/update-singbox.sh >/tmp/auto2.out 2>&1
rc=$?
assert_rc "$rc" 0 "cron 更新脚本执行成功"
assert_file /etc/sing-box/config.json "配置已更新"
if [ -d /tmp/sbshell-config.lock ]; then fail "锁目录残留"; else pass "锁目录已释放"; fi

start=$(date +%s)
run_with_timeout /etc/sing-box/update-singbox.sh >/tmp/auto3.out 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
assert_rc "$rc" 0 "第二次执行成功"
if [ "$elapsed" -lt 60 ]; then pass "第二次执行立即完成（${elapsed}s）"; else fail "第二次执行耗时 ${elapsed}s，疑似陈旧锁"; fi

suite_begin "openwrt manual_input releases its lock and cleans temp files"
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
rm -rf /tmp/sbshell-config.lock
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
printf '%s\n' "$VALID_CLIENT_CONFIG" > /tmp/existing-config.json
cp /tmp/existing-config.json /etc/sing-box/config.json
cat > /etc/sing-box/defaults.conf <<'EOF'
BACKEND_URL=https://backend.test
SUBSCRIPTION_URL=tk?token=demo
TPROXY_TEMPLATE_URL=https://tpl.test/template.json
TUN_TEMPLATE_URL=https://tpl.test/template.json
EOF
fixture_write template.json "$VALID_CLIENT_CONFIG"
printf '\n\n\ny\n' | run_with_timeout bash /etc/sing-box/scripts/manual_input.sh >/tmp/manual.out 2>&1
rc=$?
assert_rc "$rc" 0 "manual_input.sh 完成"
if [ -d /tmp/sbshell-config.lock ]; then fail "manual_input 锁目录残留"; else pass "manual_input 锁目录已释放"; fi
leftovers=$(ls -A /etc/sing-box/ 2>/dev/null | grep -c '^\.config.json.backup\|^\.manual.conf.backup' || true)
assert_eq "$leftovers" "0" "临时/备份文件已清理"
assert_file /etc/sing-box/manual.conf "manual.conf 已写入"

suite_begin "openwrt: script-update lock (A-15) serializes menu.sh and update_scripts.sh"

# 抽出两处内联锁实现：它们必须逐字一致（批次 4 的“内联副本对齐”要求）。
extract_scripts_lock() {
    awk '
        /^SCRIPTS_LOCK_DIR=/ { p = 1 }
        p { print }
        p && /^}$/ { n++ ; if (n == 2) exit }
    ' "$1"
}

lock_a=$(extract_scripts_lock "$SBSHELL_SRC/openwrt/update_scripts.sh")
lock_b=$(extract_scripts_lock "$SBSHELL_SRC/openwrt/menu.sh")
if [ -z "$lock_a" ] || [ -z "$lock_b" ]; then
    fail "无法从两个入口抽出脚本更新锁实现（awk 锚点可能被改动）"
else
    pass "两个入口都包含脚本更新锁实现"
    hash_a=$(printf '%s\n' "$lock_a" | sha256sum | cut -d' ' -f1)
    hash_b=$(printf '%s\n' "$lock_b" | sha256sum | cut -d' ' -f1)
    assert_eq "$hash_a" "$hash_b" "两处锁实现逐字一致（sha256 前缀 ${hash_a%${hash_a#????????????}}）"
fi

assert_grep 'acquire_scripts_lock || exit 1' "$SBSHELL_SRC/openwrt/update_scripts.sh" \
    "update_scripts.sh 取锁失败即退出，不与另一入口交错写脚本"
assert_grep 'release_scripts_lock; rm -rf' "$SBSHELL_SRC/openwrt/update_scripts.sh" \
    "update_scripts.sh 的 EXIT trap 会释放脚本锁"
assert_eq "$(grep -c 'update_scripts_locked' "$SBSHELL_SRC/openwrt/menu.sh")" "4" \
    "menu.sh：1 处定义 + 3 处调用都走持锁包装"
assert_no_grep '^    update_scripts || ' "$SBSHELL_SRC/openwrt/menu.sh" \
    "menu.sh 不再直接调用无锁的 update_scripts"

# 行为：抽出锁实现并用 2 秒阈值驱动（真机阈值是 900 秒，不能真的等）。
driver=$(mktemp -d)
{
    printf '%s\n' "$lock_a"
    cat <<'EOS'
SCRIPTS_LOCK_TIMEOUT=2
LOCK_TIMEOUT=2
rm -rf "$SCRIPTS_LOCK_DIR"
acquire_scripts_lock || { echo 'first-acquire-failed'; exit 1; }
case "$(cat "$SCRIPTS_LOCK_DIR/pid" 2>/dev/null)" in
    ''|*[!0-9]*) echo 'pid-not-numeric' ;;
    *) echo 'pid-numeric' ;;
esac
if acquire_scripts_lock; then echo 'second-acquire-unexpected'; else echo 'second-acquire-timeout'; fi
release_scripts_lock
if [ -d "$SCRIPTS_LOCK_DIR" ]; then echo 'release-failed'; else echo 'released'; fi
# 陈旧锁（mtime 远早于阈值）必须被接管，否则一次异常退出就会永久卡住自动更新。
mkdir -p "$SCRIPTS_LOCK_DIR"
printf 'not-a-pid\n' > "$SCRIPTS_LOCK_DIR/pid"
touch -d '2000-01-01 00:00:00' "$SCRIPTS_LOCK_DIR" 2>/dev/null || true
if acquire_scripts_lock; then echo 'stale-lock-taken-over'; else echo 'stale-lock-not-taken'; fi
release_scripts_lock
EOS
} > "$driver/lock_driver.sh"
out=$(run_with_timeout bash "$driver/lock_driver.sh" 2>&1)
rc=$?
assert_not_rc "$rc" 124 "锁驱动没有挂住"
assert_rc "$rc" 0 "锁驱动成功"
assert_contains "$out" "pid-numeric" "持锁后写入纯数字 pid"
assert_contains "$out" "second-acquire-timeout" "本进程持锁时再次获取必须超时返回非 0"
assert_contains "$out" "released" "release 删掉锁目录"
assert_contains "$out" "stale-lock-taken-over" "陈旧锁被接管"
rm -rf "$driver"

suite_end
