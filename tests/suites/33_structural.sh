#!/usr/bin/env bash
# 33_structural.sh
# 第五轮结构性重构的回归：公共库收敛、目录级原子部署、防火墙两阶段提交、
# 自更新归档缓存、防火墙参数集中化。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SRC="${SBSHELL_SRC:-/src}"
O="$SRC/openwrt"

suite_begin "公共库：一份实现，多个入口 source"

assert_file "$O/lib.sh" "存在 openwrt/lib.sh"
for fn in install read_value resolve_default valid_url valid_subscription \
          warn_plaintext_http redact_url download_failure_reason \
          acquire_lock release_lock commit_file; do
    assert_grep "^[[:space:]]*${fn}() {" "$O/lib.sh" "lib.sh 提供 $fn"
done
# 各自仍保留内联兜底的只有 bootstrap/ash/cron 三处（+ lib 本体）。
assert_grep 'command -v install' "$SRC/sbshall.sh" "sbshall.sh 保持自包含（早于 lib 落地）"
assert_grep 'command -v install' "$O/menu.sh" "menu.sh 保持自包含（引导时只装了它）"
assert_grep '^#!/bin/sh' "$O/install_singbox.sh" "install_singbox.sh 是 ash，不能加载 bash 库"
assert_grep 'command -v install' "$O/lib.sh" "lib.sh 自己定义兜底"
# 其余入口必须加载库，且缺库时给出可执行的提示。
for f in manual_input.sh manual_update.sh set_defaults.sh auto_update.sh \
         configure_tproxy.sh configure_tun.sh clean_nft.sh switch_mode.sh update_ui.sh; do
    assert_grep '_sbshell_lib_dir/lib.sh' "$O/$f" "$f 加载公共库"
    assert_grep '缺少 lib.sh' "$O/$f" "$f 缺库时明确报错"
done
# 收敛后不应再有第二份实现。
assert_eq "$(grep -c '^download_failure_reason() {' "$O/manual_input.sh" "$O/manual_update.sh" | awk -F: '{s+=$2} END {print s+0}')" "0" \
    "交互脚本不再内联 download_failure_reason"
assert_eq "$(grep -c '^valid_url() {' "$O/manual_input.sh" "$O/manual_update.sh" "$O/set_defaults.sh" | awk -F: '{s+=$2} END {print s+0}')" "0" \
    "交互脚本不再内联 valid_url"

suite_begin "公共库行为：commit_file / 默认值 / 失败原因"

probe_dir=$(mktemp -d)
printf 'new-content\n' > "$probe_dir/src"
if ( . "$O/lib.sh" && commit_file "$probe_dir/src" "$probe_dir/dst" 0600 ); then
    if [ "$(cat "$probe_dir/dst")" = "new-content" ]; then pass "commit_file 提交内容正确"; else fail "commit_file 内容不对"; fi
    if [ -z "$(ls -a "$probe_dir" | grep -E '^\.dst\.' || true)" ]; then pass "commit_file 无临时文件残留"; else fail "commit_file 残留临时文件"; fi
else
    fail "commit_file 返回非 0"
fi
if ( . "$O/lib.sh" && commit_file "$probe_dir/missing" "$probe_dir/dst2" 0600 ); then
    fail "源文件缺失时 commit_file 不应成功"
else
    if [ ! -e "$probe_dir/dst2" ]; then pass "源缺失时目标不被创建"; else fail "源缺失却创建了目标"; fi
fi
rm -rf "$probe_dir"

suite_begin "目录级原子部署：整体 rename，不再逐文件覆盖"

for f in menu.sh update_scripts.sh; do
    assert_grep 'NEW_SCRIPTS_DIR=$(mktemp -d "${SCRIPT_DIR}\.new\.XXXXXX")' "$O/$f" "$f 先建整套新目录"
    assert_grep 'mv "$SCRIPT_DIR" "$OLD_SCRIPTS_DIR"' "$O/$f" "$f 旧目录先改名"
    assert_grep 'mv "$NEW_SCRIPTS_DIR" "$SCRIPT_DIR"' "$O/$f" "$f 新目录整体就位"
    assert_grep '\.initialized' "$O/$f" "$f 保留目录里的非脚本文件（.initialized 等）"
    assert_no_grep 'install -o root -g root -m 0755 "\$TMP_DIR/\$script" "\$SCRIPT_DIR/\$script"' "$O/$f" \
        "$f 不再逐文件写进运行目录"
done
# 脚本集合必须包含公共库，否则更新后所有入口都会报「缺少 lib.sh」。
assert_grep 'SCRIPTS=(.*lib\.sh.*menu\.sh)' "$O/menu.sh" "menu.sh 的下载清单包含 lib.sh"
assert_grep 'SCRIPTS=(.*lib\.sh.*menu\.sh)' "$O/update_scripts.sh" "update_scripts.sh 的下载清单包含 lib.sh"

suite_begin "自更新归档缓存：raw/api 都失败时只下一次 tar.gz"

for f in menu.sh update_scripts.sh; do
    assert_grep 'SBSHELL_ARCHIVE_CACHE' "$O/$f" "$f 定义归档缓存"
    assert_grep 'SBSHELL_ARCHIVE_REF' "$O/$f" "$f 按 commit 复用缓存"
done
# 缓存命中时必须复用同一个文件（不再每次 mktemp 下载）。
ref_hits=$(grep -c 'SBSHELL_ARCHIVE_REF:-' "$O/menu.sh" "$O/update_scripts.sh" | awk -F: '{s+=$2} END {print s+0}')
assert_eq "$ref_hits" "2" "两个更新入口都先查缓存再下载"

suite_begin "防火墙两阶段提交：pending 期间也认作 Sbshell 所有"

assert_grep 'STATE_PENDING=' "$O/configure_tproxy.sh" "tproxy 写 pending 标记"
assert_grep 'TUN_STATE_PENDING=' "$O/configure_tun.sh" "tun 写 pending 标记"
assert_grep 'fw_owned() {' "$O/configure_tproxy.sh" "tproxy 用 fw_owned 判定归属"
assert_grep 'fw_owned() {' "$O/clean_nft.sh" "clean_nft 用 fw_owned 判定归属"
assert_grep '\.pending' "$O/clean_nft.sh" "clean_nft 会清理 pending"
# 三个 fw_owned 实现必须一致（否则某条路径会把 pending 当成外来对象而拒绝）。
h1=$(awk '/^fw_owned\(\)/{p=1} p{print} p&&/^}$/{exit}' "$O/configure_tproxy.sh" | sha256sum | cut -d' ' -f1)
h2=$(awk '/^fw_owned\(\)/{p=1} p{print} p&&/^}$/{exit}' "$O/configure_tun.sh" | sha256sum | cut -d' ' -f1)
h3=$(awk '/^fw_owned\(\)/{p=1} p{print} p&&/^}$/{exit}' "$O/clean_nft.sh" | sha256sum | cut -d' ' -f1)
assert_eq "$h1" "$h2" "tproxy 与 tun 的 fw_owned 逐字一致"
assert_eq "$h1" "$h3" "clean_nft 与 tproxy 的 fw_owned 逐字一致"

fw=$(mktemp)
awk '/^fw_owned\(\)/{p=1} p{print} p&&/^}$/{exit}' "$O/configure_tproxy.sh" > "$fw"
probe_fw() { ( . "$fw"; fw_owned "$1" ); }
d=$(mktemp -d)
printf 'OWNER=sbshell\n' > "$d/a.state"
printf 'OWNER=sbshell\n' > "$d/b.state.pending"
printf 'OWNER=other\n' > "$d/c.state"
probe_fw "$d/a.state" && pass "有 state 且 OWNER=sbshell → owned" || fail "有 state 时判定失败"
probe_fw "$d/b.state" && pass "只有 pending（崩溃窗口）→ owned" || fail "只有 pending 时被当成外来对象"
probe_fw "$d/c.state" && fail "外来 state 被误判为 owned" || pass "外来 state → 拒绝"
probe_fw "$d/none.state" && fail "不存在的 state 被误判为 owned" || pass "不存在 → 拒绝"
rm -rf "$d" "$fw"

suite_begin "防火墙参数集中化"

assert_grep '^SBSHELL_ROUTING_MARK=' "$O/lib.sh" "lib.sh 定义 ROUTING_MARK"
assert_grep '^SBSHELL_PROXY_FWMARK=' "$O/lib.sh" "lib.sh 定义 PROXY_FWMARK"
assert_grep '^SBSHELL_ROUTE_TABLE=' "$O/lib.sh" "lib.sh 定义 ROUTE_TABLE"
assert_grep '^SBSHELL_RULE_PREF=' "$O/lib.sh" "lib.sh 定义 RULE_PREF"
assert_grep '^SBSHELL_RESERVED_V4=' "$O/lib.sh" "lib.sh 定义保留网段"
for f in configure_tproxy.sh configure_tun.sh clean_nft.sh; do
    assert_grep 'SBSHELL_ROUTE_TABLE' "$O/$f" "$f 使用集中化的路由表号"
done
# 不再出现写死的旧常量（state 文件里的 RULE_PREF=$ACTUAL_RULE_PREF 是运行值，不算）。
assert_eq "$(grep -cE '^(ROUTING_MARK|PROXY_FWMARK|PROXY_ROUTE_TABLE|RULE_PREF)=[0-9]' "$O/configure_tproxy.sh" "$O/configure_tun.sh" "$O/clean_nft.sh" | awk -F: '{s+=$2} END {print s+0}')" "0" \
    "防火墙脚本不再各自写死常量"

suite_end
