#!/usr/bin/env bash
# 27_batch10_diagnostics.sh —— 批次 10：失败诊断一致性 + 注释漂移 + check_environment 加固。
#
#   P2 同一个订阅地址在「初始化」与「更新」两条路径上给出完全不同的失败信息：
#      manual_input.sh 有 download_failure_reason()（curl 码/HTTP 码 → 中文原因），
#      manual_update.sh / auto_update.sh 只有一句「下载失败」。
#   P2 update_ui.sh 生成给 cron 的那份脚本把每个拒绝点都写成 `rm -f "$list"; exit 1`，
#      cron 日志里看不出是缺 unzip、含不安全条目还是超过 200 MiB 上限。
#   P3 menu.sh 注释仍在讲早已不存在的 ghfast 代理。
#   P3 check_environment.sh 没有 set、错误没走 stderr。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SRC="${SBSHELL_SRC:-/src}"

# 统计匹配行数：用 ERE（grep -cE）—— 本套件要匹配**字面**的 `||`，而 GNU BRE 里 `\|` 是“或”运算符。
count_in() {
    local pattern="$1" file="$2"
    grep -cE -- "$pattern" "$file" 2>/dev/null || true
}

extract_failure_reason() {
    awk '/^download_failure_reason\(\) \{/ { p = 1 } p { print } p && /^\}$/ { exit }' "$1"
}

suite_begin "批次10 P2：三份 download_failure_reason 逐字一致"

extract_failure_reason "$SRC/openwrt/manual_input.sh" > /tmp/g27-input.txt
extract_failure_reason "$SRC/openwrt/manual_update.sh" > /tmp/g27-update.txt
extract_failure_reason "$SRC/openwrt/auto_update.sh" > /tmp/g27-auto.txt
assert_grep 'reason_rc' /tmp/g27-input.txt "抽到了原因解释函数"
if cmp -s /tmp/g27-input.txt /tmp/g27-update.txt; then pass "manual_update.sh 的副本与 manual_input.sh 逐字一致"
else fail "manual_update.sh 的副本与 manual_input.sh 不一致"; fi
if cmp -s /tmp/g27-input.txt /tmp/g27-auto.txt; then pass "auto_update.sh 的副本与 manual_input.sh 逐字一致"
else fail "auto_update.sh 的副本与 manual_input.sh 不一致"; fi

suite_begin "批次10 P2：更新路径也报出具体原因与 HTTP 码"

for f in manual_update.sh auto_update.sh; do
    assert_grep "%{http_code}" "$SRC/openwrt/$f" "$f 的 curl 带 -w 取 HTTP 状态码"
    assert_grep 'download_http_code' "$SRC/openwrt/$f" "$f 读取 HTTP 状态码"
    assert_grep 'download_failure_reason "\$download_rc"' "$SRC/openwrt/$f" "$f 用退出码翻译原因"
done
assert_no_grep '新配置下载失败，已保留之前的 config.json' "$SRC/openwrt/manual_update.sh" \
    "manual_update.sh 不再只说「下载失败」"
assert_no_grep "echo '配置下载失败。' >&2" "$SRC/openwrt/auto_update.sh" \
    "auto_update.sh 不再只说「下载失败」"

suite_begin "批次10 P2：cron 版 UI 更新器不再静默拒绝"

assert_grep 'die() {' "$SRC/openwrt/update_ui.sh" "生成体里定义了 die()"
assert_eq "$(count_in 'rm -f "\$list"; exit 1' "$SRC/openwrt/update_ui.sh")" "0" \
    "validate_archive 的拒绝点不再静默 exit 1"
assert_grep '压缩包校验未通过' "$SRC/openwrt/update_ui.sh" "压缩包校验失败有明确原因"
assert_grep '等待面板更新锁超时' "$SRC/openwrt/update_ui.sh" "锁等待超时有明确原因"
assert_grep 'UI 目录替换失败' "$SRC/openwrt/update_ui.sh" "UI 替换失败有明确原因"
assert_grep 'chown root:root 失败' "$SRC/openwrt/update_ui.sh" "chown 失败有明确原因"
assert_grep 'UI 下载地址必须是 HTTPS' "$SRC/openwrt/update_ui.sh" "URL 校验失败有明确原因"

suite_begin "批次10 P3：注释漂移与 check_environment 加固"

assert_eq "$(count_in 'ghfast' "$SRC/openwrt/menu.sh")" "0" "menu.sh 不再提早已不存在的 ghfast 代理"
assert_grep 'REPO_RAW' "$SRC/openwrt/menu.sh" "菜单注释改讲 REPO_RAW 覆盖"
assert_grep '^set -uo pipefail' "$SRC/openwrt/check_environment.sh" "check_environment.sh 有了 set -u/pipefail"
assert_eq "$(count_in '^set -euo pipefail' "$SRC/openwrt/check_environment.sh")" "0" \
    "故意不加 set -e（| head -n1 的 SIGPIPE + pipefail 会把脚本带走）"
assert_grep '此脚本需要 root 权限" >&2' "$SRC/openwrt/check_environment.sh" "root 检查的错误走 stderr"

suite_end
