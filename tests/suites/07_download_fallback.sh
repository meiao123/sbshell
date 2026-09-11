#!/usr/bin/env bash
# 07_download_fallback.sh
# 回归：raw.githubusercontent.com TLS/SAN 异常时，脚本更新必须能安全回退到 GitHub Contents API。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

suite_begin "script download has an API fallback for broken raw host TLS"

for f in sbshall.sh openwrt/menu.sh openwrt/update_scripts.sh; do
    if grep -q '^github_api_download() {' "$SBSHELL_SRC/$f"; then
        pass "$f 提供 GitHub Contents API 回退下载"
    else
        fail "$f 缺少 GitHub Contents API 回退下载"
    fi
    assert_grep 'api\.github\.com/repos/meiao123/sbshell/contents/' "$SBSHELL_SRC/$f" "$f 使用 GitHub Contents API"
    assert_grep 'base64 -d' "$SBSHELL_SRC/$f" "$f 对 API 返回内容做 base64 解码"
done

suite_end
