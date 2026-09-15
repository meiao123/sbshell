#!/usr/bin/env bash
# 04_config_update.sh
# 审计 P1-3.2 / P1-3.3 / P2-15 / P2-1 回归：订阅配置更新路径。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

NEW_CONFIG='{"log":{"level":"warn"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}'

suite_begin "manual_update: empty backend (direct template URL) is supported (P1-3.2)"

reset_stub_state
reset_singbox_dir
reset_fixtures
install_repo_scripts debian
printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json
cat > /etc/sing-box/manual.conf <<'EOF'
BACKEND_URL=
SUBSCRIPTION_URL=
TEMPLATE_URL=https://tpl.test/template.json
EOF
fixture_write template.json "$NEW_CONFIG"

run_with_timeout bash /etc/sing-box/scripts/manual_update.sh >/tmp/mu1.out 2>&1
rc=$?
assert_rc "$rc" 0 "留空后端地址时仍能更新（旧代码直接 exit 1）"
assert_eq "$(jq -c . /etc/sing-box/config.json)" "$(printf '%s' "$NEW_CONFIG" | jq -c .)" "配置已更新"
assert_grep 'tpl.test/template.json' "$SBSHELL_STUB_STATE/curl.log" "直接使用模板地址下载"
if grep -q '/config/' "$SBSHELL_STUB_STATE/curl.log"; then fail "不应拼接后端路径"; else pass "未拼接后端路径"; fi

suite_begin "manual_update yes: interactive re-entry rewrites manual.conf (P1-3.3)"

printf 'https://backend2.test\nsub2?token=x\nhttps://tpl.test/template.json\n' \
    | run_with_timeout bash /etc/sing-box/scripts/manual_update.sh yes >/tmp/mu2.out 2>&1
rc=$?
assert_rc "$rc" 0 "manual_update.sh yes 成功"
assert_grep '^BACKEND_URL=https://backend2.test$' /etc/sing-box/manual.conf "manual.conf 已写回新的后端地址"
assert_grep 'backend2.test/config/sub2?token=x&file=https://tpl.test/template.json' "$SBSHELL_STUB_STATE/curl.log" "拼装出的订阅 URL 正确"

suite_begin "manual_update: hostile subscription string is rejected (P2-15)"

printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json
cat > /etc/sing-box/manual.conf <<'EOF'
BACKEND_URL=https://backend.test
SUBSCRIPTION_URL=tk&file=https://evil.test/x
TEMPLATE_URL=https://tpl.test/template.json
EOF
run_with_timeout bash /etc/sing-box/scripts/manual_update.sh >/tmp/mu3.out 2>&1
rc=$?
assert_not_rc "$rc" 0 "含 &file= 的订阅地址被拒绝"
assert_eq "$(jq -c . /etc/sing-box/config.json)" "$(printf '%s' "$VALID_CLIENT_CONFIG" | jq -c .)" "拒绝时未改动现有配置"

suite_begin "manual_update: invalid downloaded config is not committed (atomicity)"

fixture_write template.json 'this is not json'
run_with_timeout bash /etc/sing-box/scripts/manual_update.sh >/tmp/mu4.out 2>&1
rc=$?
assert_not_rc "$rc" 0 "无效配置导致失败"
assert_eq "$(jq -c . /etc/sing-box/config.json)" "$(printf '%s' "$VALID_CLIENT_CONFIG" | jq -c .)" "失败时保留旧配置"

suite_begin "update_config.sh: empty input keeps the stored URL (P1-3.8)"

reset_stub_state
reset_singbox_dir
reset_fixtures
install_repo_scripts debian
fixture_write template.json "$NEW_CONFIG"
printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json

printf 'https://tpl.test/template.json\n' | run_with_timeout bash /etc/sing-box/scripts/update_config.sh >/tmp/uc1.out 2>&1
assert_rc "$?" 0 "首次写入配置链接成功"
assert_grep 'tpl.test/template.json' /etc/sing-box/config.url "config.url 已记录"

printf 'y\n\n' | run_with_timeout bash /etc/sing-box/scripts/update_config.sh >/tmp/uc2.out 2>&1
rc=$?
assert_rc "$rc" 0 "选择更换但直接回车时不应报错（旧代码会清空链接并 exit 1）"
assert_grep 'tpl.test/template.json' /etc/sing-box/config.url "原链接被保留"

suite_begin "update_config.sh: Enter generates a local random-credential config (P2-1)"

reset_stub_state
reset_singbox_dir
reset_fixtures
install_repo_scripts debian
printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json

printf '\n\n\n\nn\n' | run_with_timeout bash /etc/sing-box/scripts/update_config.sh >/tmp/uc3.out 2>&1
rc=$?
assert_rc "$rc" 0 "回车走本地生成路径"
assert_file /etc/sing-box/config.json "config.json 已生成"
if jq empty /etc/sing-box/config.json 2>/dev/null; then pass "生成的配置是合法 JSON"; else fail "生成的配置不是合法 JSON"; fi
assert_eq "$(jq -r '.inbounds | length' /etc/sing-box/config.json)" "2" "默认生成 SS + VLESS-REALITY 两个入站"
if grep -q 'REPLACE_ME' /etc/sing-box/config.json; then fail "生成结果里存在占位符"; else pass "凭据为本地随机生成"; fi
assert_eq "$(jq -r '.inbounds[0].password | length > 10' /etc/sing-box/config.json)" "true" "SS 密码已随机生成"

suite_begin "manual_update: ubus 'Command failed' noise from the init script must not leak"

# 真机回归（ImmortalWrt 25.12.2，包管理器提供的 init 脚本）：菜单 2 更新成功后仍会漏出一行
#   Command failed: ubus call service delete { "name": "sing-box" } (Not found)
# 旧的 `'/^Command failed: Not found$/d'` 只压得住短形态。这里让服务脚本吐出两种形态，
# 验证更新路径把两条都吃掉（不是只做静态断言）。
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json
cat > /etc/sing-box/manual.conf <<'EOF'
BACKEND_URL=
SUBSCRIPTION_URL=
TEMPLATE_URL=https://tpl.test/template.json
EOF
fixture_write template.json "$NEW_CONFIG"

export SBSHELL_INITD_NOISE=1
run_with_timeout bash /etc/sing-box/scripts/manual_update.sh >/tmp/mu_noise.out 2>&1
rc=$?
unset SBSHELL_INITD_NOISE
assert_rc "$rc" 0 "服务脚本吐 ubus 噪音时更新依然成功"
assert_no_grep 'Command failed' /tmp/mu_noise.out "短形态与带命令名的长形态都被过滤"
assert_grep '配置更新并启动成功' /tmp/mu_noise.out "成功提示照常打印"

suite_end
