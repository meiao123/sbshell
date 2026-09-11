#!/usr/bin/env bash
# 回归：选项 2 配置更新、选项 9 脚本更新、二级 UI 菜单与通知颜色。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

suite_begin "openwrt: option 2 asks before resetting saved endpoints"
assert_grep "是否重新设置配置文件地址" "$SBSHELL_SRC/openwrt/manual_update.sh" "选项 2 先询问是否重新设置地址"
assert_grep "确认地址无误" "$SBSHELL_SRC/openwrt/manual_update.sh" "新地址填写后要求二次确认"
assert_grep "BACKEND_URL=" "$SBSHELL_SRC/openwrt/manual_update.sh" "新后端地址写入记录"
assert_grep "SUBSCRIPTION_URL=" "$SBSHELL_SRC/openwrt/manual_update.sh" "新订阅地址写入记录"
assert_grep "TEMPLATE_URL=" "$SBSHELL_SRC/openwrt/manual_update.sh" "新配置文件地址写入记录"
assert_grep 'config\.json\.bak' "$SBSHELL_SRC/openwrt/manual_update.sh" "旧 config 备份在同级目录"
assert_grep '新配置下载失败' "$SBSHELL_SRC/openwrt/manual_update.sh" "下载失败提示并保留旧配置"
assert_grep '新配置验证失败' "$SBSHELL_SRC/openwrt/manual_update.sh" "验证失败提示并保留旧配置"
assert_grep '已恢复旧配置' "$SBSHELL_SRC/openwrt/manual_update.sh" "启动失败时恢复旧配置"

suite_begin "openwrt: option 9 downloads scripts from openwrt/"
assert_grep 'download_repo_file "openwrt/\$script"' "$SBSHELL_SRC/openwrt/update_scripts.sh" "选项 9 使用正确的 openwrt 路径"

suite_begin "openwrt: UI menu separators and colored notifications"
assert_grep "^    echo '========'$" "$SBSHELL_SRC/openwrt/update_ui.sh" "二级菜单顶部有分隔线"
separator_count=$(grep -c "^    echo '========'$" "$SBSHELL_SRC/openwrt/update_ui.sh" || true)
assert_eq "$separator_count" "2" "请选择前也有二级菜单分隔线"
assert_grep 'GREEN=.*RED=' "$SBSHELL_SRC/openwrt/update_ui.sh" "UI 脚本定义成功/失败颜色"
assert_grep 'GREEN.*UI 安装完成' "$SBSHELL_SRC/openwrt/update_ui.sh" "UI 安装成功使用绿色通知"
assert_grep 'RED.*>&2' "$SBSHELL_SRC/openwrt/update_ui.sh" "UI 失败通知使用红色"
assert_grep 'check_ui()' "$SBSHELL_SRC/openwrt/update_ui.sh" "检查 UI 保留为独立函数"

suite_end
