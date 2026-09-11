#!/usr/bin/env bash
# 01_debian_menu_flow.sh
# 审计 P0-1 回归：debian/menu.sh 的客户端初始化必须能跑完。
# 旧代码在 download_all_scripts 的 `trap ... RETURN` 上，会因为父函数返回时再次触发、
# local 变量已销毁（set -u）而以 "tmpdir: unbound variable" 中止整个菜单。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

suite_begin "debian menu: client initialization completes end-to-end (P0-1)"

reset_stub_state
reset_singbox_dir
reset_fixtures
install_repo_scripts debian

# 模拟发行版包已经提供一份可用的默认配置（真实 Debian 包里也有 config.json）
printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json

# 脚本自更新/订阅下载的 fixture：仓库里的真实脚本 + 一份客户端模板
for f in "$SBSHELL_SRC"/debian/*.sh; do cp "$f" "$SBSHELL_FIXTURES/"; done
fixture_write template.json "$VALID_CLIENT_CONFIG"

cat > /etc/sing-box/defaults.conf <<'EOF'
BACKEND_URL=https://backend.test
SUBSCRIPTION_URL=tk?token=demo
TPROXY_TEMPLATE_URL=https://tpl.test/template.json
TUN_TEMPLATE_URL=https://tpl.test/template.json
EOF

# 输入顺序：角色=1 -> 回车开始 -> switch_mode=1(TProxy) -> 三个地址回车使用默认 -> 确认 y -> 菜单退出 0
output=$(printf '1\n\n1\n\n\n\ny\n0\n' | run_with_timeout bash /etc/sing-box/scripts/menu.sh 2>&1)
rc=$?

assert_rc "$rc" 0 "menu.sh 正常退出（旧代码会 unbound variable 中止）"
assert_not_contains "$output" "unbound variable" "没有出现 unbound variable"
assert_contains "$output" "客户端初始化完成" "客户端初始化完成"
assert_contains "$output" "sbshell客户端管理菜单" "进入了客户端管理菜单"
assert_file /etc/sing-box/.initialized "写入 .initialized"
assert_file /etc/sing-box/config.json "生成 config.json"

if command -v jq >/dev/null 2>&1; then
    assert_eq "$(jq -c . /etc/sing-box/config.json 2>/dev/null)" \
              "$(printf '%s' "$VALID_CLIENT_CONFIG" | jq -c .)" \
              "config.json 内容来自订阅模板"
fi

assert_eq "$(cat /etc/sing-box/mode.conf)" "MODE=TProxy" "mode.conf 记录 TProxy"

expected_scripts=$(ls "$SBSHELL_SRC"/debian/*.sh | wc -l)
installed_scripts=$(ls /etc/sing-box/scripts/*.sh 2>/dev/null | wc -l)
assert_eq "$installed_scripts" "$expected_scripts" "全部脚本已事务式安装"

assert_grep "tpl.test/template.json" "$SBSHELL_STUB_STATE/curl.log" "按默认模板地址下载配置"

if nft_table_exists sing-box; then pass "TProxy 表已下发"; else fail "TProxy 表未下发"; fi
if ip_rules | grep -q "fwmark 0x1 lookup 100"; then pass "mark-1 策略路由已创建"; else fail "mark-1 策略路由缺失"; fi

# 二次启动：脚本已存在，走 check_and_download_scripts 分支，同样不能崩
output2=$(printf '0\n' | run_with_timeout bash /etc/sing-box/scripts/menu.sh 2>&1)
rc2=$?
assert_rc "$rc2" 0 "已初始化状态下启动菜单正常退出"
assert_not_contains "$output2" "unbound variable" "二次启动没有 unbound variable"

suite_end
