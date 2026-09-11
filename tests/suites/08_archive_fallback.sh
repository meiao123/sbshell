#!/usr/bin/env bash
# 08_archive_fallback.sh
# 回归：raw 与 Contents API 均不可用时，脚本下载必须还有 GitHub commit archive 兜底，并兼容 OpenWrt BusyBox mktemp。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

suite_begin "script download has a GitHub commit archive fallback"

for f in sbshall.sh openwrt/menu.sh openwrt/update_scripts.sh; do
    if grep -q '^github_archive_download() {' "$SBSHELL_SRC/$f"; then
        pass "$f 提供 GitHub commit archive 回退下载"
    else
        fail "$f 缺少 GitHub commit archive 回退下载"
    fi
    assert_grep 'github\.com/meiao123/sbshell/archive/' "$SBSHELL_SRC/$f" "$f 使用 GitHub 官方 commit archive"
    assert_grep 'tar' "$SBSHELL_SRC/$f" "$f 能从 archive 提取文件"
    assert_grep 'mktemp /tmp/sbshell-archive\.XXXXXX([^A-Za-z0-9]|$)' "$SBSHELL_SRC/$f" "$f 使用 BusyBox 兼容的 mktemp 模板"
done

assert_grep '^REPO_RAW=' "$SBSHELL_SRC/openwrt/menu.sh" "openwrt/menu.sh 定义 REPO_RAW，避免 set -u 下变量未定义"

suite_begin "release pin has been removed; main is the only update source"
for f in sbshall.sh openwrt/menu.sh openwrt/update_scripts.sh debian/menu.sh; do
    if grep -Eq 'RELEASE|RELEASE_REF|resolve_release_ref' "$SBSHELL_SRC/$f"; then
        fail "$f 仍依赖 RELEASE 发布指针"
    else
        pass "$f 不再依赖 RELEASE 发布指针"
    fi
done
assert_grep '"main"' "$SBSHELL_SRC/sbshall.sh" "sbshall.sh 使用 main 作为最新代码来源"
assert_grep 'main/openwrt/' "$SBSHELL_SRC/openwrt/menu.sh" "OpenWrt 更新路径直接指向 main"
assert_grep 'main/debian/' "$SBSHELL_SRC/debian/menu.sh" "Debian 更新路径直接指向 main"

suite_end
