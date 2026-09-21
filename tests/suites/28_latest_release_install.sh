#!/usr/bin/env bash
# 28_latest_release_install.sh —— A-29：sing-box 内核与 UI 都改为「安装时取上游最新稳定版」。
#
#   内核（install_singbox.sh）：apk 固件优先装上游官方 OpenWrt 包
#       sing-box_<版本>_openwrt_<apk --print-arch>.apk，任何一步失败回退发行版软件包。
#   UI（update_ui.sh）：默认面板地址不再固定版本，改为解析 zashboard 最新 release 的
#       dist-cdn-fonts.zip（缺失时任意 dist-*.zip），失败回退到内置固定地址。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SRC="${SBSHELL_SRC:-/src}"
FIX="$SBSHELL_FIXTURES"

count_in() { grep -c -- "$1" "$2" 2>/dev/null || true; }

extract_fn() {   # extract_fn <文件> <函数名>
    awk -v fn="$2" '$0 ~ "^" fn "\\(\\)" { p=1 } p { print } p && /^}$/ { exit }' "$1"
}

suite_begin "A-29 内核：apk 固件走上游官方 OpenWrt 包，失败回退 feed"

KERNEL="$SRC/openwrt/install_singbox.sh"
assert_grep 'install_latest_singbox() {' "$KERNEL" "定义了上游最新版安装函数"
assert_grep 'apk --print-arch' "$KERNEL" "用 apk --print-arch 取当前架构（与资产名一一对应）"
assert_grep 'SBSHELL_SINGBOX_SOURCE' "$KERNEL" "提供 latest/feed 逃生开关"
assert_grep 'sha256sum' "$KERNEL" "对下载的包做 sha256 校验"
assert_grep 'rollback_to_feed' "$KERNEL" "有回滚到发行版包的路径"
# 回退必须落在主流程里：上游路径失败要真的去装 feed 包
assert_grep 'pkg_install sing-box' "$KERNEL" "主流程保留发行版包安装（回退目标）"
assert_min_count "$KERNEL" '\[ "\$PKG_MGR" = apk \]' 1 "opkg 固件不走上游路径（上游没有 .ipk）"
# 版本核对：安装后必须与解析出的版本一致，否则回滚
assert_grep '安装后版本核对失败' "$KERNEL" "安装后核对版本，不一致即回滚"

# pick_asset 的行为：按字段顺序（name → digest → browser_download_url）取出目标架构的资产
RELEASE_JSON=$(mktemp)
cat > "$RELEASE_JSON" <<'JSON'
{
  "tag_name": "v9.9.9",
  "assets": [
    { "url": "https://api.github.com/x/1", "name": "sing-box_9.9.9_linux_amd64.deb",
      "size": 111, "digest": "sha256:aaaa", "browser_download_url": "https://example.test/deb" },
    { "url": "https://api.github.com/x/2", "name": "sing-box_9.9.9_openwrt_x86_64.apk",
      "size": 222, "digest": "sha256:bbbb", "browser_download_url": "https://example.test/apk" }
  ]
}
JSON
pick_src=$(mktemp)
extract_fn "$KERNEL" pick_asset > "$pick_src"
assert_grep 'browser_download_url' "$pick_src" "成功抽出 pick_asset"
# shellcheck disable=SC1090
( . "$pick_src"
  out=$(pick_asset "$RELEASE_JSON" x86_64)
  printf '%s\n' "$out" > /tmp/a29-pick.txt
  missing=$(pick_asset "$RELEASE_JSON" aarch64_cortex-a53)
  printf '%s\n' "$missing" > /tmp/a29-pick-missing.txt ) 2>/dev/null
assert_eq "$(sed -n '1p' /tmp/a29-pick.txt)" "https://example.test/apk" "选中当前架构的资产（跳过 .deb）"
assert_eq "$(sed -n '2p' /tmp/a29-pick.txt)" "sha256:bbbb" "取到该资产的 digest"
assert_eq "$(sed -n '3p' /tmp/a29-pick.txt)" "222" "取到该资产的字节大小"
assert_eq "$(cat /tmp/a29-pick-missing.txt)" "" "架构无对应资产时返回空（调用方回退 feed）"
rm -f "$pick_src" "$RELEASE_JSON" /tmp/a29-pick.txt /tmp/a29-pick-missing.txt

suite_begin "A-29 UI：默认面板改为解析最新 release，失败回退固定地址"

UI="$SRC/openwrt/update_ui.sh"
assert_grep 'ZASHBOARD_RELEASE_API' "$UI" "声明了 zashboard release API"
assert_grep 'resolve_latest_zashboard_url() {' "$UI" "交互路径有解析函数"
assert_grep 'fetch_latest_zashboard_url() {' "$UI" "cron 生成体也有一份（两个脚本互不 source）"
assert_grep 'dist-cdn-fonts.zip' "$UI" "优先取 cdn-fonts 构建资产"
assert_grep 'URL=${URL:-https://github.com/Zephyruso/zashboard/releases/download/v3.28.0/dist-cdn-fonts.zip}' "$UI" \
    "解析失败时回退到内置固定地址"
assert_grep 'resolve_latest_zashboard_url || true' "$UI" "选项 1 先解析最新、再回退"

# 用 curl 桩驱动解析函数：优先 cdn-fonts；只有其它 dist-*.zip 时取其一；请求失败则返回非 0
printf '{"tag_name":"v9.9.9","assets":[{"name":"dist-firasans-only.zip","url":"https://api.github.com/x/1","size":1,"digest":"sha256:1","browser_download_url":"https://example.test/other.zip"},{"name":"dist-cdn-fonts.zip","url":"https://api.github.com/x/2","size":2,"digest":"sha256:2","browser_download_url":"https://example.test/cdn.zip"}]}\n' > "$FIX/latest"
res_src=$(mktemp)
extract_fn "$UI" resolve_latest_zashboard_url > "$res_src"
assert_grep 'browser_download_url' "$res_src" "成功抽出 resolve_latest_zashboard_url"
ZASHBOARD_RELEASE_API="https://api.github.com/repos/Zephyruso/zashboard/releases/latest"
export ZASHBOARD_RELEASE_API
# shellcheck disable=SC1090
pref=$( ( . "$res_src"; resolve_latest_zashboard_url ) 2>/dev/null )
assert_eq "$pref" "https://example.test/cdn.zip" "优先选择 dist-cdn-fonts.zip"
printf '{"assets":[{"name":"dist-misans-only.zip","url":"https://api.github.com/x/1","size":1,"digest":"sha256:1","browser_download_url":"https://example.test/misans.zip"}]}\n' > "$FIX/latest"
# shellcheck disable=SC1090
alt=$( ( . "$res_src"; resolve_latest_zashboard_url ) 2>/dev/null )
assert_eq "$alt" "https://example.test/misans.zip" "没有 cdn-fonts 时退而取任意 dist-*.zip"
printf '{"assets":[{"name":"index.html","url":"https://api.github.com/x/1","size":1,"digest":"sha256:1","browser_download_url":"https://example.test/none"}]}\n' > "$FIX/latest"
# shellcheck disable=SC1090
( . "$res_src"; resolve_latest_zashboard_url ) >/dev/null 2>&1
assert_not_rc "$?" 0 "没有合适资产时返回非 0（调用方回退固定地址）"
rm -f "$res_src" "$FIX/latest"

suite_end
