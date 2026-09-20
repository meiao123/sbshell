#!/usr/bin/env bash
# 批次 1（安全 P0/P1）回归套件。
#
# 覆盖：
#   F1 tests/run.sh --local 不再无条件破坏宿主机（显式确认 + host_guard 备份/恢复）
#   F5 openwrt 三个脚本的 URL 校验/下载收敛为 HTTPS（面板本地探活保持 http，有意）
#
# 说明：F5 在容器内是静态断言；F1 的"拒绝运行"是行为断言。
# 原 F2/F3/F4 针对 debian/ 的修复已随 Debian 支持一并移除。
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib/harness.sh
. "$HERE/../lib/harness.sh"

SRC="${SBSHELL_SRC:-/src}"

# -------------------------------------------------------- F5 仅 HTTPS
suite_begin "batch1 F5: OpenWrt 配置 URL 仅允许 HTTPS"

for f in manual_input.sh manual_update.sh set_defaults.sh; do
    assert_grep 'valid_url() { \[\[ "\$1" =~ \^https://' "$SRC/openwrt/$f" \
        "openwrt/$f 的 URL 校验只接受 https"
done
assert_no_grep "proto '=http,https'" "$SRC/openwrt/manual_input.sh" \
    "配置下载不再允许明文 HTTP"
assert_grep "proto '=https'" "$SRC/openwrt/manual_input.sh" "配置下载使用 https"
assert_grep "proto '=http,https'" "$SRC/openwrt/update_ui.sh" \
    "面板本地探活仍允许 http（有意）"

# --------------------------------------------------- F1 宿主机护栏
suite_begin "batch1 F1: --local 不再无条件破坏宿主机"

assert_grep 'SBSHELL_ALLOW_LOCAL_DESTRUCTIVE' "$SRC/tests/run.sh" "run.sh 要求显式确认"
assert_grep 'SBSHELL_LOCAL=1' "$SRC/tests/run.sh" "--local 导出 SBSHELL_LOCAL"
assert_file "$SRC/tests/lib/host_guard.sh" "存在宿主机备份/恢复护栏"
assert_grep 'host_guard_init' "$SRC/tests/all.sh" "all.sh 在 local 模式初始化护栏"
assert_grep 'host_guard_restore' "$SRC/tests/all.sh" "all.sh 注册退出恢复"
assert_grep '/etc/ssh/sshd_config' "$SRC/tests/lib/host_guard.sh" "护栏覆盖 sshd_config"
assert_grep '/etc/sing-box' "$SRC/tests/lib/host_guard.sh" "护栏覆盖 /etc/sing-box"

# 行为断言：未显式确认时 --local 必须拒绝（且不触碰任何真实路径）。
out=$(run_with_timeout env -u SBSHELL_ALLOW_LOCAL_DESTRUCTIVE bash "$SRC/tests/run.sh" --local 2>&1)
rc=$?
assert_rc "$rc" 1 "未确认时 --local 拒绝运行"
assert_contains "$out" "SBSHELL_ALLOW_LOCAL_DESTRUCTIVE=1" "拒绝信息给出显式确认方式"
assert_contains "$out" "/etc/ssh/sshd_config" "拒绝信息列出会被覆写的真实路径"

suite_end
