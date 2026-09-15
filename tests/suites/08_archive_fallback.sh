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
    assert_grep 'mktemp /tmp/sbshell-archive\.XXXXXX' "$SBSHELL_SRC/$f" "$f 使用 BusyBox 兼容的 mktemp 模板"
done

assert_grep '^export REPO_RAW=' "$SBSHELL_SRC/openwrt/menu.sh" "openwrt/menu.sh 定义 REPO_RAW，避免 set -u 下变量未定义"

suite_begin "release pin has been removed; main is the only update source"
for f in sbshall.sh openwrt/menu.sh openwrt/update_scripts.sh debian/menu.sh; do
    # 去掉注释行再判断：脚本里保留“已移除 RELEASE 声明”的说明是好事，
    # 这里只禁止代码/下载路径仍然依赖发布指针（与 workflow 的令牌检查一致）。
    if grep -vE '^[[:space:]]*#' "$SBSHELL_SRC/$f" | grep -Eq 'RELEASE|RELEASE_REF|resolve_release_ref'; then
        fail "$f 仍依赖 RELEASE 发布指针"
    else
        pass "$f 不再依赖 RELEASE 发布指针"
    fi
done
assert_grep '"main"' "$SBSHELL_SRC/sbshall.sh" "sbshall.sh 使用 main 作为最新代码来源"
assert_grep 'download_repo_file "openwrt/[^"]*" "main"' "$SBSHELL_SRC/openwrt/menu.sh" "OpenWrt 更新路径直接取自 main"
assert_grep 'main/debian' "$SBSHELL_SRC/debian/menu.sh" "Debian 更新路径直接指向 main"
assert_grep 'main/debian' "$SBSHELL_SRC/debian/update_scripts.sh" "Debian 自更新路径直接指向 main"

suite_begin "HTTP and HTTPS config URLs are accepted"
assert_grep 'https?://' "$SBSHELL_SRC/openwrt/manual_input.sh" "manual_input.sh 接受 HTTP/HTTPS URL"
assert_grep --proto "$SBSHELL_SRC/openwrt/manual_input.sh" "manual_input.sh 使用显式协议白名单"
assert_grep "=http,https" "$SBSHELL_SRC/openwrt/manual_input.sh" "配置下载同时允许 HTTP 与 HTTPS"
assert_grep 'https?://' "$SBSHELL_SRC/openwrt/set_defaults.sh" "set_defaults.sh 接受 HTTP/HTTPS URL"

suite_begin "config URL uses the documented subscription/template concatenation"
assert_grep 'FULL_URL="\${BACKEND_URL%/}/config/\${SUBSCRIPTION_URL}&file=\${TEMPLATE_URL}"' "$SBSHELL_SRC/openwrt/manual_input.sh" "后端配置 URL 保持 /config/订阅地址&file=模板地址 拼接规则"

suite_begin "initialization marker is committed before optional config download"
initialize_line=$(grep -n '^initialize() {' "$SBSHELL_SRC/openwrt/menu.sh" | cut -d: -f1)
marker_line=$(grep -n 'touch "\$INITIALIZED_FILE"' "$SBSHELL_SRC/openwrt/menu.sh" | cut -d: -f1)
manual_input_line=$(grep -n 'run manual_input.sh' "$SBSHELL_SRC/openwrt/menu.sh" | head -n1 | cut -d: -f1)
start_line=$(grep -n 'run start_singbox.sh' "$SBSHELL_SRC/openwrt/menu.sh" | head -n1 | cut -d: -f1)
if [ -n "$initialize_line" ] && [ -n "$marker_line" ] && [ -n "$manual_input_line" ] && [ -n "$start_line" ] \
    && [ "$marker_line" -gt "$initialize_line" ] \
    && [ "$marker_line" -lt "$manual_input_line" ] \
    && [ "$marker_line" -lt "$start_line" ]; then
    pass "初始化状态标记在配置下载和服务启动前提交"
else
    fail "初始化状态标记仍在配置下载失败后才提交"
fi
suite_end
