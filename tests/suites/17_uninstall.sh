#!/usr/bin/env bash
# 17_uninstall.sh —— 批次 3 补：卸载路径的行为覆盖。
#
# 为什么需要：卸载是两个平台**唯一**执行 `rm -rf /etc/sing-box` 的路径，此前只有静态
# grep 断言 —— 只要那几行字面量还在文件里，回归就会"通过"，而卸载本身有没有真的清干净、
# 失败时会不会留下半拆状态，从来没有被执行过。
#
# 这里把 openwrt/menu.sh 里真实的 confirm_yes 与 uninstall_sbshell **原样抽出**执行
# （不复制改写），覆盖三种行为：
#   1) 回答 n     → 什么都不动
#   2) 停止失败   → 中止卸载，配置目录与 cron 条目必须保留（否则留下半拆状态）
#   3) 正常卸载   → 清理干净，且不误删无关 init 脚本
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

MENU="$SBSHELL_SRC/openwrt/menu.sh"

# 抽出真实函数体（suite 06 已有同款抽取模式）。
awk '/^confirm_yes\(\)/{p=1} p{print} p&&/^\}$/{exit}' "$MENU" > /tmp/u17-confirm.sh
awk '/^uninstall_sbshell\(\)/{p=1} p{print} p&&/^\}$/{exit}' "$MENU" > /tmp/u17-uninstall.sh
assert_grep 'uninstall_sbshell' /tmp/u17-uninstall.sh "抽到 uninstall_sbshell 函数体"
assert_grep 'confirm_yes' /tmp/u17-confirm.sh "抽到 confirm_yes 函数体"

cat > /tmp/u17-driver.sh <<'EOS'
set -uo pipefail
# 抽出的函数体依赖 menu.sh 顶部的颜色变量与 SCRIPT_DIR，这里按 menu.sh 的定义补齐。
RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
SCRIPT_DIR=/etc/sing-box/scripts
. /tmp/u17-confirm.sh
. /tmp/u17-uninstall.sh
uninstall_sbshell
EOS

setup_uninstall_case() {
    reset_singbox_dir
    install_repo_scripts openwrt
    reset_openwrt_dirs
    reset_stub_state
    mkdir -p /etc/cron.d /etc/crontabs
    : > /etc/cron.d/sbshell-ui
    printf '%s\n' '*/5 * * * * /etc/sing-box/update-ui.sh # sbshell-ui-auto-update' > /etc/crontabs/root
    : > "$SBSHELL_STUB_STATE/singbox_active"      # 让 pidof 认为服务在跑（否则不进入 stop 分支）
    : > "$SBSHELL_STUB_STATE/nft/inet__sing-box"  # 让 clean_nft 有表可删
}

run_uninstall() {
    printf '%b' "$1" | run_with_timeout bash /tmp/u17-driver.sh 2>&1
}

# --------------------------------------------------------------- 1) 回答 n
suite_begin "uninstall: 回答 n 时不得改动任何东西"
setup_uninstall_case
out=$(run_uninstall 'n\n')
rc=$?
assert_contains "$out" "已取消卸载" "回答 n 时提示已取消"
assert_rc "$rc" 0 "取消卸载返回 0"
assert_dir /etc/sing-box "取消卸载后配置目录仍在"
assert_file /etc/cron.d/sbshell-ui "取消卸载后面板 cron 文件仍在"

# ------------------------------------------- 2) 停止失败必须中止卸载
suite_begin "uninstall: 停止 sing-box 失败时必须中止卸载"
setup_uninstall_case
printf '#!/bin/sh\nexit 1\n' > /etc/init.d/sing-box
chmod 0755 /etc/init.d/sing-box
out=$(run_uninstall 'y\n')
rc=$?
assert_contains "$out" "停止 sing-box 失败，已取消卸载" "停止失败时明确中止"
assert_not_rc "$rc" 0 "停止失败时返回非 0"
assert_dir /etc/sing-box "停止失败后配置目录必须保留（否则留下半拆状态）"
assert_file /etc/cron.d/sbshell-ui "停止失败后面板 cron 文件保留"

# ------------------------------------------------------- 3) 正常卸载
suite_begin "uninstall: 正常卸载要清干净且不误删无关文件"
setup_uninstall_case
out=$(run_uninstall 'y\n')
rc=$?
assert_rc "$rc" 0 "正常卸载返回 0"
assert_contains "$out" "Sbshell 与 sing-box 配置目录已清理" "给出卸载完成提示"
assert_no_file /etc/sing-box "配置目录已删除"
assert_no_file /etc/cron.d/sbshell-ui "面板 cron 文件已删除"
assert_no_grep 'sbshell-ui-auto-update' /etc/crontabs/root "crontab 里的 sbshell 条目已删除"
assert_file /etc/init.d/cron "无关 init 脚本未被误删"

suite_end
