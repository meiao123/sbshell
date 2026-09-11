#!/usr/bin/env bash
# 03_locks.sh
# 审计 P0-3 / P2-18 回归：配置锁的获取与释放。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

suite_begin "openwrt auto-update lock is released (P0-3)"

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

run_with_timeout /etc/sing-box/update-singbox.sh >/tmp/auto2.out 2>&1
rc=$?
assert_rc "$rc" 0 "cron 更新脚本执行成功"
assert_file /etc/sing-box/config.json "配置已更新"
if [ -d /tmp/sbshell-config.lock ]; then
    fail "锁目录残留（旧代码用 rmdir 删不掉含 pid 的目录）"
else
    pass "锁目录已释放"
fi

start=$(date +%s)
run_with_timeout /etc/sing-box/update-singbox.sh >/tmp/auto3.out 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
assert_rc "$rc" 0 "第二次执行成功"
if [ "$elapsed" -lt 60 ]; then
    pass "第二次执行立即完成（${elapsed}s，旧代码会空转到 LOCK_TIMEOUT=900s）"
else
    fail "第二次执行耗时 ${elapsed}s，疑似在等待陈旧锁"
fi

suite_begin "openwrt manual_input releases its lock and cleans temp files (P2-18)"

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
fixture_write manual.conf 'BACKEND_URL=https://backend.test
SUBSCRIPTION_URL=tk?token=demo
TEMPLATE_URL=https://tpl.test/template.json'

output=$(printf '\n\n\ny\n' | run_with_timeout bash /etc/sing-box/scripts/manual_input.sh 2>&1)
rc=$?
assert_rc "$rc" 0 "manual_input.sh 完成"
if [ -d /tmp/sbshell-config.lock ]; then fail "manual_input 锁目录残留"; else pass "manual_input 锁目录已释放"; fi
leftovers=$(ls -A /etc/sing-box/ 2>/dev/null | grep -c '^\.config.json.backup\|^\.manual.conf.backup' || true)
assert_eq "$leftovers" "0" "临时/备份文件已清理（TMP_FILES 不再被 EXIT trap 覆盖丢失）"
assert_file /etc/sing-box/manual.conf "manual.conf 已写入"

suite_begin "debian: concurrent updates serialize via flock"

reset_stub_state
reset_singbox_dir
reset_fixtures
install_repo_scripts debian
printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json
cat > /etc/sing-box/manual.conf <<'EOF'
BACKEND_URL=https://backend.test
SUBSCRIPTION_URL=tk?token=demo
TEMPLATE_URL=https://tpl.test/template.json
EOF
fixture_write template.json "$VALID_CLIENT_CONFIG"
printf '1\n12\n' | run_with_timeout bash /etc/sing-box/scripts/auto_update.sh >/tmp/dauto.out 2>&1
assert_rc "$?" 0 "debian 自动更新脚本生成成功"

run_with_timeout /etc/sing-box/update-singbox.sh >/tmp/d1.out 2>&1 &
p1=$!
run_with_timeout /etc/sing-box/update-singbox.sh >/tmp/d2.out 2>&1 &
p2=$!
wait "$p1"; rc1=$?
wait "$p2"; rc2=$?
assert_rc "$rc1" 0 "并发执行 1 成功"
assert_rc "$rc2" 0 "并发执行 2 成功"
assert_file /etc/sing-box/config.json "并发后配置仍存在"
leftover_tmp=$(ls -d /tmp/sbshell-auto.* 2>/dev/null | wc -l)
assert_eq "$leftover_tmp" "0" "没有残留临时目录"

suite_end
