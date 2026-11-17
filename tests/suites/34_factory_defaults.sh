#!/usr/bin/env bash
# 34_factory_defaults.sh —— 出厂默认地址：后端 / 订阅 / TUN 模板（1.14.x）
#
# 覆盖三类回归：
#   a) 出厂值集中在 lib.sh（单一事实来源），菜单 1/2/6 都从这里回退；
#   b) 菜单 6 提示里显示默认值、全回车即落盘出厂值、再次执行可覆盖；
#   c) 选项 2 不再把订阅地址显示成「已隐藏」；显式留空（键存在但为空）不会重回到出厂值。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

O="$SBSHELL_SRC/openwrt"

suite_begin "出厂默认：lib.sh 单一事实来源"

assert_grep '^SBSHELL_FACTORY_BACKEND_URL=' "$O/lib.sh" "lib.sh 定义后端出厂值"
assert_grep '^SBSHELL_FACTORY_SUBSCRIPTION_URL=' "$O/lib.sh" "lib.sh 定义订阅出厂值"
assert_grep '^SBSHELL_FACTORY_TUN_TEMPLATE_URL=.*1\.14\.x/' "$O/lib.sh" "TUN 模板出厂值指向 1.14.x"
assert_grep '^factory_default() {' "$O/lib.sh" "lib.sh 提供 factory_default"
assert_grep '^default_or_factory() {' "$O/lib.sh" "lib.sh 提供 default_or_factory"

suite_begin "出厂默认：菜单 6 / 选项 2 / 初始化都用同一份默认值"

assert_no_grep '1\.2\.x/' "$O/set_defaults.sh" "菜单 6 不再引用 1.2.x 路径"
assert_no_grep 'DEFAULT_TUN_TEMPLATE_URL=' "$O/set_defaults.sh" "菜单 6 不再保留旧常量"
assert_grep '回车使用默认' "$O/set_defaults.sh" "菜单 6 提示里显示默认值"
assert_grep 'factory_default BACKEND_URL' "$O/set_defaults.sh" "菜单 6 后端默认来自 lib.sh"
assert_grep 'factory_default TUN_TEMPLATE_URL' "$O/set_defaults.sh" "菜单 6 TUN 模板默认来自 lib.sh"

assert_no_grep '已隐藏' "$O/manual_update.sh" "选项 2 不再隐藏订阅地址"
assert_grep 'default_or_factory BACKEND_URL' "$O/manual_update.sh" "选项 2 后端默认统一解析"
assert_grep '订阅地址(留空使用默认: \${default_subscription' "$O/manual_update.sh" "选项 2 订阅提示回显完整地址"
assert_grep '^hint_local_backend() {' "$O/manual_update.sh" "选项 2 下载失败给出本机后端提示"

assert_grep 'default_or_factory BACKEND_URL' "$O/manual_input.sh" "初始化后端默认统一解析"
assert_grep 'factory_default TUN_TEMPLATE_URL' "$O/manual_input.sh" "初始化 TUN 模板默认来自 lib.sh"
assert_no_grep 'DEFAULT_TUN_TEMPLATE_URL=' "$O/manual_input.sh" "初始化不再保留旧常量"

suite_begin "菜单 12：部署/重建后端已接线"

assert_grep '12\. 部署/重建后端' "$O/menu.sh" "菜单列表出现 12 项"
assert_grep '12) run_action deploy_backend\.sh' "$O/menu.sh" "选择 12 调用 deploy_backend.sh"
assert_grep 'deploy_backend\.sh' "$O/menu.sh" "menu.sh 的 SCRIPTS 清单包含 deploy_backend.sh"
assert_grep 'deploy_backend\.sh' "$O/update_scripts.sh" "update_scripts.sh 的 SCRIPTS 清单包含 deploy_backend.sh"

suite_begin "出厂默认：菜单 6 全回车落盘出厂值，再次执行可覆盖"

printf '\n\n\n\n' | run_with_timeout bash "$O/set_defaults.sh" >/tmp/a34-set1.out 2>&1
assert_rc "$?" 0 "菜单 6 全回车执行成功"
assert_grep '^BACKEND_URL=http://127\.0\.0\.1:5000/$' /etc/sing-box/defaults.conf "后端落盘为出厂值"
assert_grep '^SUBSCRIPTION_URL=.*target=sing-box$' /etc/sing-box/defaults.conf "订阅落盘为出厂值"
assert_grep '^TUN_TEMPLATE_URL=.*1\.14\.x/config_sb_Tun_fakeip\.json$' /etc/sing-box/defaults.conf "TUN 模板落盘为 1.14.x 出厂值"

printf 'http://10.0.0.9:7777/\nhttp://10.0.0.9:3001/custom\n\nhttps://example.test/tun.json\n' \
    | run_with_timeout bash "$O/set_defaults.sh" >/tmp/a34-set2.out 2>&1
assert_rc "$?" 0 "菜单 6 输入自定义值执行成功"
assert_grep '^BACKEND_URL=http://10\.0\.0\.9:7777/$' /etc/sing-box/defaults.conf "再次执行可覆盖后端"
assert_grep '^SUBSCRIPTION_URL=http://10\.0\.0\.9:3001/custom$' /etc/sing-box/defaults.conf "再次执行可覆盖订阅"
assert_grep '^TUN_TEMPLATE_URL=https://example\.test/tun\.json$' /etc/sing-box/defaults.conf "再次执行可覆盖模板"

suite_begin "出厂默认：显式留空不回退，键缺失才回退"

DF=/tmp/a34-defaults.conf
MF=/tmp/a34-manual.conf
printf 'BACKEND_URL=\n' > "$DF"
: > "$MF"
got=$( . "$O/lib.sh"; DEFAULTS_FILE="$DF"; MANUAL_FILE="$MF"; default_or_factory BACKEND_URL )
assert_eq "$got" '' "显式留空时不再回退到出厂值"
rm -f "$DF"
got=$( . "$O/lib.sh"; DEFAULTS_FILE="$DF"; MANUAL_FILE="$MF"; default_or_factory BACKEND_URL )
assert_eq "$got" 'http://127.0.0.1:5000/' "键缺失时回退到出厂值"
got=$( . "$O/lib.sh"; DEFAULTS_FILE="$DF"; MANUAL_FILE="$MF"; factory_default TUN_TEMPLATE_URL )
assert_contains "$got" '1.14.x/config_sb_Tun_fakeip.json' "factory_default 返回 1.14.x 模板"
rm -f "$DF" "$MF" /tmp/a34-set1.out /tmp/a34-set2.out

suite_end
