#!/usr/bin/env bash
# 30_pinned_download.sh —— 回归：更新前先解析 main commit，整个下载/校验批次固定到该 commit。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
suite_begin "pinned update flow: main -> commit SHA -> download -> hash verify -> API/archive fallback"
for f in sbshall.sh openwrt/menu.sh openwrt/update_scripts.sh; do
    assert_grep '^resolve_main_commit() {' "$SBSHELL_SRC/$f" "$f 实现 main commit SHA 解析"
    assert_grep 'git/ref/heads/\\$MAIN_REF' "$SBSHELL_SRC/$f" "$f 从 GitHub ref API 获取 main"
    assert_grep '^github_archive_download() {' "$SBSHELL_SRC/$f" "$f 保留 commit archive 兜底"
    assert_grep 'archive/\\$ref\\.tar\\.gz' "$SBSHELL_SRC/$f" "$f archive 使用固定 ref"
    assert_grep 'download_repo_file' "$SBSHELL_SRC/$f" "$f 统一走传输层下载"
done
assert_grep 'download_bootstrap_menu "\\$commit"' "$SBSHELL_SRC/sbshall.sh" "引导阶段固定 commit 下载 menu.sh + SHA256SUMS"
assert_grep 'verify_manifest_entry "\\$manifest_output" "openwrt/menu.sh"' "$SBSHELL_SRC/sbshall.sh" "引导阶段校验 menu.sh SHA256"
for f in openwrt/menu.sh openwrt/update_scripts.sh; do
    assert_grep 'for transport in raw api archive; do' "$SBSHELL_SRC/$f" "$f 按 Raw → API → archive 顺序自动回退"
    assert_grep 'verify_script_hashes' "$SBSHELL_SRC/$f" "$f 每个传输层成功后执行 SHA256 校验"
    assert_grep 'Raw 下载失败或完整性校验失败' "$SBSHELL_SRC/$f" "$f Raw 校验失败会切 API"
    assert_grep 'Contents API 下载失败或完整性校验失败' "$SBSHELL_SRC/$f" "$f API 校验失败会切 archive"
done
suite_end
