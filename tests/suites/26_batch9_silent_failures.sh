#!/usr/bin/env bash
# 26_batch9_silent_failures.sh —— 批次 9：A-23 静默失败 + A-26 /tmp 状态文件抢先创建窗口。
#
#   A-23 四处「失败被吞掉却仍报成功 / 无任何解释」：
#        stop_singbox.sh       clean_nft.sh 失败时无解释退出
#        manage_autostart.sh   sbshell-firewall disable 失败被 `|| true` 吞掉仍报成功
#        update_ui.sh / auto_update.sh  cron restart 失败被吞掉仍报「已设置」
#        update_scripts.sh     下载校验失败只静默 exit 1
#   A-26 三处下载进度状态文件：mktemp 后立刻 rm、再由子 shell `>` 重建 → 同名符号链接抢注窗口
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SRC="${SBSHELL_SRC:-/src}"

# 统计匹配行数：把模式单独传进来，避免在命令替换里嵌套引号。
# 用 ERE（grep -cE）：本套件要在模式里匹配**字面**的 `||`，而 GNU BRE 里 `\|` 是“或”
# 运算符 —— 写成 BRE 会让模式变成「A 或 空 或 B」，空分支匹配每一行（CI 上表现为 got 135/509/237，
# 正好是三个文件的总行数）。ERE 下 `\|` 才是字面 `|`。
count_in() {
    local pattern="$1" file="$2"
    grep -cE -- "$pattern" "$file" 2>/dev/null || true
}

suite_begin "批次9 A-23：失败不再被吞掉"

assert_grep '防火墙规则清理失败' "$SRC/openwrt/stop_singbox.sh" \
    "clean_nft.sh 失败时给出明确原因"
assert_grep '可手工重试：bash \$SCRIPT_DIR/clean_nft.sh' "$SRC/openwrt/stop_singbox.sh" \
    "给出可直接执行的手工命令"
assert_eq "$(count_in 'clean_nft\.sh"$' "$SRC/openwrt/stop_singbox.sh")" "0" \
    "不再是「裸调用靠 errexit 退出」"

assert_grep '注销开机防火墙脚本失败' "$SRC/openwrt/manage_autostart.sh" \
    "sbshell-firewall disable 失败会告警"
assert_eq "$(count_in 'sbshell-firewall disable >/dev/null 2>&1 \|\| true' "$SRC/openwrt/manage_autostart.sh")" "0" \
    "不再用 || true 吞掉 disable 失败"
assert_grep 'cmd_status=1' "$SRC/openwrt/manage_autostart.sh" \
    "disable 失败并入 cmd_status，走统一的失败分支"

assert_eq "$(count_in '计划任务未生效：cron 重启失败' "$SRC/openwrt/update_ui.sh")" "1" \
    "update_ui.sh 的 cron restart 失败会告警"
assert_eq "$(count_in '计划任务未生效：cron 重启失败' "$SRC/openwrt/auto_update.sh")" "2" \
    "auto_update.sh 两处 cron restart 失败都会告警"
assert_eq "$(count_in 'cron restart >/dev/null 2>&1 \|\| true' "$SRC/openwrt/update_ui.sh")" "0" \
    "update_ui.sh 不再有被 || true 吞掉的 cron restart"
assert_eq "$(count_in 'cron restart >/dev/null 2>&1 \|\| true' "$SRC/openwrt/auto_update.sh")" "0" \
    "auto_update.sh 不再有被 || true 吞掉的 cron restart"

assert_grep '下载失败或为空' "$SRC/openwrt/update_scripts.sh" \
    "脚本下载校验失败会说明是哪个文件"

suite_begin "批次9 A-26：状态文件不再先删后建"

# 关键不变式：mktemp 拿到名字之后不得紧跟 `rm -f`（否则名字对任何进程都可创建，
# /tmp 的 sticky 位保护不了不存在的名字，本地用户可抢先建同名符号链接）。
bad=$(awk '
    /mktemp \/tmp\/sbshell-(auto|update|config)-status/ {
        getline nxt
        if (nxt ~ /^[[:space:]]*rm -f/) print FILENAME ": " nxt
    }
' "$SRC"/openwrt/*.sh)
assert_eq "$bad" "" "mktemp 之后不再紧跟 rm -f"

assert_grep 'A-26：不要 rm' "$SRC/openwrt/auto_update.sh" "auto_update.sh 注明了保留原因"
assert_grep 'A-26：不要 rm' "$SRC/openwrt/manual_update.sh" "manual_update.sh 注明了保留原因"
assert_grep 'A-26：不要 rm' "$SRC/openwrt/manual_input.sh" "manual_input.sh 注明了保留原因"
# 子 shell 仍然用 `>` 写入我们自己持有的那个 0600 名字（语义与旧写法一致）
assert_grep '> "\$download_status"' "$SRC/openwrt/auto_update.sh" "状态文件仍由子 shell 写入"
assert_grep '> "\$download_status"' "$SRC/openwrt/manual_update.sh" "状态文件仍由子 shell 写入"

suite_begin "批次9 其他：shellcheck SC2034 遗留"

assert_grep 'export VALID_CLIENT_CONFIG=' "$SRC/tests/lib/harness.sh" \
    "跨套件使用的夹具常量显式导出（消除 SC2034）"

suite_end
