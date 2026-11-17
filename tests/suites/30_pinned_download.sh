#!/usr/bin/env bash
# 30_pinned_download.sh —— 回归：更新前先解析 main commit，整个下载/校验批次固定到该 commit。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
suite_begin "pinned update flow: main -> commit SHA -> download -> hash verify -> API/archive fallback"
for f in sbshall.sh openwrt/menu.sh openwrt/update_scripts.sh; do
    assert_grep '^resolve_main_commit() {' "$SBSHELL_SRC/$f" "$f 实现 main commit SHA 解析"
    assert_grep 'git/ref/heads/\$MAIN_REF' "$SBSHELL_SRC/$f" "$f 从 GitHub ref API 获取 main"
    assert_grep '^github_archive_download() {' "$SBSHELL_SRC/$f" "$f 保留 commit archive 兜底"
    assert_grep 'archive/\$ref\.tar\.gz' "$SBSHELL_SRC/$f" "$f archive 使用固定 ref"
    assert_grep 'download_repo_file' "$SBSHELL_SRC/$f" "$f 统一走传输层下载"
done
assert_grep 'download_bootstrap_menu "\$commit"' "$SBSHELL_SRC/sbshall.sh" "引导阶段固定 commit 下载 menu.sh + SHA256SUMS"
assert_grep 'verify_manifest_entry "\$manifest_output" "openwrt/menu.sh"' "$SBSHELL_SRC/sbshall.sh" "引导阶段校验 menu.sh SHA256"
for f in openwrt/menu.sh openwrt/update_scripts.sh; do
    assert_grep 'for transport in raw api archive; do' "$SBSHELL_SRC/$f" "$f 按 Raw → API → archive 顺序自动回退"
    assert_grep 'verify_script_hashes' "$SBSHELL_SRC/$f" "$f 每个传输层成功后执行 SHA256 校验"
    assert_grep 'Raw 下载失败或完整性校验失败' "$SBSHELL_SRC/$f" "$f Raw 校验失败会切 API"
    assert_grep 'Contents API 下载失败或完整性校验失败' "$SBSHELL_SRC/$f" "$f API 校验失败会切 archive"
done

suite_begin "commit 解析：api.github.com 限流（403）时改走 github.com 兜底"

# api.github.com 的未认证配额是 60 次/小时/IP，出口被 CGNAT/其它工具打满就 403；
# github.com 本体（atom feed 与 commit/main.patch）不受该配额限制，必须作为兜底。
for f in sbshall.sh openwrt/menu.sh openwrt/update_scripts.sh; do
    assert_grep '^GITHUB_WEB_BASE=' "$SBSHELL_SRC/$f" "$f 声明 github.com 兜底端点"
    assert_grep 'commits/\$MAIN_REF\.atom' "$SBSHELL_SRC/$f" "$f 尝试 atom feed"
    assert_grep 'commit/\$MAIN_REF\.patch' "$SBSHELL_SRC/$f" "$f 尝试 patch 首行"
    assert_grep 'SBSHELL_PINNED_COMMIT=<40 位 commit>' "$SBSHELL_SRC/$f" "$f 403 时给出可执行的绕过提示"
done

extract_fn() { # extract_fn <文件> <函数名>
    awk -v fn="$2" '$0 ~ "^" fn "\\(\\)" { p = 1 } p { print } p && /^}$/ { exit }' "$1"
}
h1=$(extract_fn "$SBSHELL_SRC/sbshall.sh" resolve_main_commit | sha256sum | cut -d' ' -f1)
h2=$(extract_fn "$SBSHELL_SRC/openwrt/menu.sh" resolve_main_commit | sha256sum | cut -d' ' -f1)
h3=$(extract_fn "$SBSHELL_SRC/openwrt/update_scripts.sh" resolve_main_commit | sha256sum | cut -d' ' -f1)
assert_eq "$h1" "$h2" "sbshall.sh 与 menu.sh 的 commit 解析逐字一致"
assert_eq "$h1" "$h3" "sbshall.sh 与 update_scripts.sh 的 commit 解析逐字一致"

# 用桩 curl 驱动解析函数：API 一律 403；atom / patch 可分别注入成功。
stub_dir=$(mktemp -d)
cat > "$stub_dir/curl" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_LOG:-/dev/null}"
out=''
url=''
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -H|--proto|--connect-timeout|--max-time|--tlsv1.2|--fail|--silent|--show-error|--location) shift ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    *api.github.com*) echo 'curl: (22) The requested URL returned error: 403' >&2; exit 22 ;;
    *.atom) [ "${STUB_ATOM_OK:-0}" = 1 ] || { echo 'curl: (22) The requested URL returned error: 403' >&2; exit 22; }
            printf '<id>tag:github.com,2008:Grit::Commit/%s</id>\n' "$STUB_SHA" > "$out"; exit 0 ;;
    *.patch) [ "${STUB_PATCH_OK:-0}" = 1 ] || { echo 'curl: (22) The requested URL returned error: 403' >&2; exit 22; }
             printf 'From %s Mon Sep 17 00:00:00 2001\n' "$STUB_SHA" > "$out"; exit 0 ;;
    *) exit 22 ;;
esac
EOS
chmod 0755 "$stub_dir/curl"
fn_src=$(mktemp)
extract_fn "$SBSHELL_SRC/sbshall.sh" resolve_main_commit > "$fn_src"
sha=0123456789abcdef0123456789abcdef01234567
run_resolve() {
    ( . "$fn_src"
      MAIN_REF=main
      GITHUB_API_BASE="https://api.github.com/repos/meiao123/sbshell"
      GITHUB_WEB_BASE="https://github.com/meiao123/sbshell"
      PATH="$stub_dir:$PATH"
      export PATH
      resolve_main_commit )
}
log=$(mktemp)
out=$(STUB_LOG="$log" STUB_SHA="$sha" STUB_ATOM_OK=1 run_resolve); rc=$?
assert_rc "$rc" 0 "API 403 + atom 可用时解析成功"
assert_eq "$out" "$sha" "从 atom feed 取到 commit"
assert_grep 'api\.github\.com' "$log" "确实先尝试过 API"
out=$(STUB_LOG="$log" STUB_SHA="$sha" STUB_ATOM_OK=0 STUB_PATCH_OK=1 run_resolve); rc=$?
assert_rc "$rc" 0 "atom 也不可用时 patch 兜底成功"
assert_eq "$out" "$sha" "从 patch 首行取到 commit"
: > "$log"
out=$(STUB_LOG="$log" STUB_SHA="$sha" STUB_ATOM_OK=0 STUB_PATCH_OK=0 run_resolve 2>/tmp/a30.err); rc=$?
assert_not_rc "$rc" 0 "所有来源都不可用时 fail-closed（绝不从可移动的 main 下载）"
assert_contains "$(cat /tmp/a30.err)" 'SBSHELL_PINNED_COMMIT' "403 时给出显式 pin 的绕过方法"
: > "$log"
out=$(SBSHELL_PINNED_COMMIT="$sha" STUB_LOG="$log" STUB_ATOM_OK=0 STUB_PATCH_OK=0 run_resolve); rc=$?
assert_rc "$rc" 0 "显式 pin 时直接返回"
assert_eq "$out" "$sha" "采用 pin 值"
assert_eq "$(wc -l < "$log")" "0" "pin 时完全不发网络请求"
rm -rf "$stub_dir" "$fn_src" "$log" /tmp/a30.err
suite_end
