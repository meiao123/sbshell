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

# ------------------------- F5（A-28 改写）：配置 URL 接受 http，下载链仍限 HTTPS
# 真机反馈：后端是 http://127.0.0.1:5000/（本机回环）却被「必须是 HTTPS URL」挡住。
# 现在的契约：后端/订阅/模板地址 http、https 都接受；非回环的明文 HTTP 只提示、不阻断；
# 拉取仓库自身文件与面板 zip 的下载链仍然只走 https。
suite_begin "batch1 F5/A-28: OpenWrt 配置 URL 接受 http，下载链仍限 HTTPS"

for f in manual_input.sh manual_update.sh set_defaults.sh; do
    assert_grep 'valid_url() { \[\[ "\$1" =~ \^https?://' "$SRC/openwrt/$f" \
        "openwrt/$f 的 URL 校验同时接受 http 与 https"
    assert_grep 'warn_plaintext_http() {' "$SRC/openwrt/$f" \
        "openwrt/$f 定义了明文 HTTP 风险提示函数"
done
for f in manual_input.sh manual_update.sh set_defaults.sh; do
    assert_grep 'warn_plaintext_http' "$SRC/openwrt/$f" "openwrt/$f 调用风险提示"
done
assert_grep "proto '=http,https'" "$SRC/openwrt/manual_input.sh" "manual_input 的配置下载允许明文 HTTP"
assert_grep "proto '=http,https'" "$SRC/openwrt/manual_update.sh" "manual_update 的配置下载允许明文 HTTP"
assert_grep "proto '=http,https'" "$SRC/openwrt/auto_update.sh" "cron 版更新脚本的配置下载允许明文 HTTP"
assert_grep 'http://\*\|https://\*' "$SRC/openwrt/auto_update.sh" "cron 版更新脚本的地址校验接受 http"
# 下载链（仓库自身文件 + 面板 zip）不得被一起放松
assert_no_grep "proto '=http,https'" "$SRC/openwrt/update_scripts.sh" "仓库脚本下载仍限 HTTPS"
assert_grep "proto '=https'" "$SRC/openwrt/update_ui.sh" "面板 zip 下载仍限 HTTPS"
assert_grep "proto '=http,https'" "$SRC/openwrt/update_ui.sh" \
    "面板本地探活仍允许 http（有意）"

suite_begin "batch1 F5/A-28: 真机回归（http 回环后端不再被拒）"

# 用与真机日志一致的输入驱动真实的 manual_input.sh：回环 http 后端 + 回环 http 订阅
# + https 模板，在确认处回答 n（不写任何文件、不碰锁），断言校验通过并到达摘要。
probe_input() { printf '%s\n' "$1" "$2" "$3" 'n'; }
LOOP_BACKEND='http://127.0.0.1:5000/'
LOOP_SUB='http://127.0.0.1:3001/tok/download?target=sing-box'
TEMPLATE_URL_PROBE='https://example.test/config.json'

out_loop=$(probe_input "$LOOP_BACKEND" "$LOOP_SUB" "$TEMPLATE_URL_PROBE" \
    | run_with_timeout bash "$SRC/openwrt/manual_input.sh" 2>&1)
assert_not_rc "$?" 124 "回环 http 场景没有挂住"
assert_contains "$out_loop" "你输入的配置信息如下" "校验通过并到达摘要+确认（http 回环后端被接受）"
assert_not_contains "$out_loop" "必须是 HTTPS" "不再出现「必须是 HTTPS URL」"
assert_not_contains "$out_loop" "使用明文 HTTP" "回环 http 不打印明文风险提示"

out_lan=$(probe_input 'http://192.168.8.9:5000/' 'http://192.168.8.9:3001/tok/download?target=sing-box' "$TEMPLATE_URL_PROBE" \
    | run_with_timeout bash "$SRC/openwrt/manual_input.sh" 2>&1)
assert_not_rc "$?" 124 "内网 http 场景没有挂住"
assert_contains "$out_lan" "使用明文 HTTP" "非回环 http 打印风险提示"
assert_contains "$out_lan" "你输入的配置信息如下" "非回环 http 仍被接受（只提示不阻断）"

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
