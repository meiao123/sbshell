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

suite_begin "A-29b：版本解析不依赖 API 配额 + 固定版本 + digest 可选"

K="$SRC/openwrt/install_singbox.sh"
assert_grep 'SINGBOX_RELEASES_LATEST=' "$K" "声明 github.com 重定向端点（零 API 配额）"
assert_grep '^resolve_latest_tag_by_redirect() {' "$K" "用 releases/latest 的 302 解析最新版本"
assert_grep '^detect_openwrt_arch() {' "$K" "架构识别独立成函数"
assert_grep 'OPENWRT_ARCH' "$K" "优先采用 /etc/os-release 的 OPENWRT_ARCH"
assert_grep '^normalize_singbox_pin() {' "$K" "支持 SBSHELL_SINGBOX_VERSION 固定版本"
assert_grep '^singbox_asset_url() {' "$K" "资产地址按上游命名规则拼装"
assert_grep 'SBSHELL_GITHUB_TOKEN' "$K" "支持 SBSHELL_GITHUB_TOKEN（5000 次/小时）"
assert_grep 'header = "Authorization: Bearer' "$K" "token 经 curl 配置文件传入（不进 argv）"
assert_grep '跳过 sha256 校验继续安装' "$K" "API 不可用时跳过 digest 校验，而不是放弃安装"
assert_grep 'os-release 2>/dev/null || true' "$K" "加载 os-release 带失败保护（ash 下 . 失败会带崩脚本）"

# 把安装逻辑抽成可驱动的片段：run_opkg + detect_openwrt_arch … install_latest_singbox
fn_head=$(mktemp)
fn_body=$(mktemp)
driver=$(mktemp)
awk '/^run_opkg\(\)/{p=1} p{print} p&&/^}$/{exit}' "$K" > "$fn_head"
awk '/^detect_openwrt_arch\(\)/{p=1} p&&/^}$/&&infunc{print; exit} p{print; if(/^install_latest_singbox\(\)/)infunc=1}' "$K" > "$fn_body"
{
    printf '%s\n' 'set -uo pipefail' 'SINGBOX_SOURCE=latest' 'PKG_MGR=apk' \
        'SBSHELL_SINGBOX_VERSION="${SBSHELL_SINGBOX_VERSION:-}"' \
        'SINGBOX_RELEASE_API=https://api.github.com/repos/SagerNet/sing-box/releases/latest' \
        'SINGBOX_RELEASES_LATEST=https://github.com/SagerNet/sing-box/releases/latest'
    cat "$fn_head" "$fn_body"
} > "$driver"
assert_grep '^install_latest_singbox() {' "$driver" "成功抽出安装逻辑（含 run_opkg）"

stub=$(mktemp -d)
state=$(mktemp -d)
PATH_SAVED=$PATH
export PATH="$stub:$PATH"
export STUB_LOG="$state/curl.log"
export STUB_VER_FILE="$state/ver"
export STUB_ARCH=x86_64
printf '1.0.0\n' > "$STUB_VER_FILE"

# mktemp 桩：把 workdir 挪出 /etc（测试不需要真实目录），必须调 /usr/bin/mktemp 否则递归
cat > "$stub/mktemp" <<'S'
#!/bin/bash
if [ "$1" = "-d" ]; then /usr/bin/mktemp -d /tmp/w.XXXXXX; else /usr/bin/mktemp /tmp/f.XXXXXX; fi
S
# curl 桩：url_effective 请求回显 STUB_EFFECTIVE；api.github.com 按 STUB_API_OK 回 403 或 JSON；
# 其余发布包地址写一个固定内容
cat > "$stub/curl" <<'S'
#!/bin/bash
argv="$*"
printf 'ARGV: %s\n' "$argv" >> "$STUB_LOG"
out=''
url=''
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$argv" in
    *url_effective*) printf '%s\n' "${STUB_EFFECTIVE:-}"; exit 0 ;;
esac
case "$url" in
    *api.github.com*) [ "${STUB_API_OK:-0}" = 1 ] || exit 22
                      cp "${STUB_JSON:-/dev/null}" "$out"; exit 0 ;;
    *) printf 'APK-CONTENT' > "$out"; exit 0 ;;
esac
S
cat > "$stub/apk" <<'S'
#!/bin/bash
case "$1" in
    --print-arch) echo "$STUB_ARCH" ;;
    fetch) exit 0 ;;
    add) for a in "$@"; do
             case "$a" in
                 *sing-box_*) v=$(printf '%s' "$a" | sed -n 's/.*sing-box_\([0-9][^_]*\)_.*/\1/p')
                              [ -n "$v" ] && printf '%s\n' "$v" > "$STUB_VER_FILE" ;;
             esac
         done
         exit 0 ;;
    *) exit 0 ;;
esac
S
cat > "$stub/sing-box" <<'S'
#!/bin/bash
if [ "${1:-}" = version ]; then
    printf 'sing-box version %s\n' "$(cat "$STUB_VER_FILE" 2>/dev/null || echo 0.0.0)"
    exit 0
fi
exit 0
S
chmod 0755 "$stub/mktemp" "$stub/curl" "$stub/apk" "$stub/sing-box"

run_install() { bash -c '. "$1"; install_latest_singbox' _ "$driver"; }
reset_case() { : > "$STUB_LOG"; printf '1.0.0\n' > "$STUB_VER_FILE"; }

# 纯函数行为
assert_eq "$(SBSHELL_SINGBOX_VERSION=1.14.4 bash -c '. "$1"; normalize_singbox_pin' _ "$driver")" \
    "v1.14.4" "固定版本规范化：1.14.4 → v1.14.4"
assert_eq "$(SBSHELL_SINGBOX_VERSION=v1.14.4 bash -c '. "$1"; normalize_singbox_pin' _ "$driver")" \
    "v1.14.4" "固定版本规范化：v1.14.4 → v1.14.4"
assert_eq "$(SBSHELL_SINGBOX_VERSION=1.14.4-beta.2 bash -c '. "$1"; normalize_singbox_pin' _ "$driver")" \
    "v1.14.4-beta.2" "固定版本规范化：接受预发布后缀"
assert_eq "$(SBSHELL_SINGBOX_VERSION=../../etc/passwd bash -c '. "$1"; normalize_singbox_pin' _ "$driver")" \
    "" "固定版本规范化：拒绝含路径分隔符的非法值"
assert_eq "$(bash -c '. "$1"; singbox_asset_url v1.14.4 x86_64' _ "$driver")" \
    "https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box_1.14.4_openwrt_x86_64.apk" \
    "资产地址符合上游命名"
assert_eq "$(bash -c '. "$1"; detect_openwrt_arch' _ "$driver")" "x86_64" "架构识别走 OPENWRT_ARCH/apk"

# 重定向解析：正常 tag、带 query、非 tag
for eff in "https://github.com/SagerNet/sing-box/releases/tag/v1.14.4" \
           "https://github.com/SagerNet/sing-box/releases/tag/v1.14.4?x=1"; do
    assert_eq "$(STUB_EFFECTIVE="$eff" bash -c '. "$1"; resolve_latest_tag_by_redirect' _ "$driver")" \
        "v1.14.4" "重定向解析：$eff"
done
assert_eq "$(STUB_EFFECTIVE="https://github.com/login" bash -c '. "$1"; resolve_latest_tag_by_redirect' _ "$driver")" \
    "" "重定向解析：非 tag 跳转返回空"

# 场景 A：API 403 + 重定向可用 → 仍装上游最新版
reset_case
out=$(STUB_EFFECTIVE="https://github.com/SagerNet/sing-box/releases/tag/v9.9.9" run_install 2>&1); rc=$?
assert_rc "$rc" 0 "API 403 时靠重定向仍能安装上游最新版"
assert_contains "$out" "已从 GitHub 发布页解析上游最新版本 9.9.9" "打印零配额解析结果"
assert_grep 'v9.9.9/sing-box_9.9.9_openwrt_x86_64.apk' "$STUB_LOG" "下载地址按上游命名拼出"
assert_eq "$(cat "$STUB_VER_FILE")" "9.9.9" "安装后版本一致"

# 场景 B：固定版本 → 不做版本解析、直接按版本拼地址
reset_case
out=$(SBSHELL_SINGBOX_VERSION=1.14.4 STUB_EFFECTIVE="https://example.test/nowhere" run_install 2>&1); rc=$?
assert_rc "$rc" 0 "固定版本安装成功"
assert_no_grep 'url_effective' "$STUB_LOG" "固定版本不发起版本解析请求"
assert_no_grep 'api.github.com' "$STUB_LOG" "固定版本也不访问 API 配额（可离线复现）"
assert_grep 'v1.14.4/sing-box_1.14.4_openwrt_x86_64.apk' "$STUB_LOG" "固定版本直接拼资产地址"

# 场景 B2：解析到的版本与 API 的 tag 不一致时，不得拿 A 的 digest 去校验 B 的包
reset_case
mismatch_json=$(mktemp)
printf '{"tag_name":"v9.9.8","assets":[{"name":"sing-box_9.9.8_openwrt_x86_64.apk","size":11,"digest":"sha256:deadbeef","browser_download_url":"https://example.test/download/v9.9.8/sing-box_9.9.8_openwrt_x86_64.apk"}]}\n' > "$mismatch_json"
out=$(STUB_API_OK=1 STUB_JSON="$mismatch_json" STUB_EFFECTIVE="https://github.com/SagerNet/sing-box/releases/tag/v9.9.9" run_install 2>&1); rc=$?
assert_rc "$rc" 0 "tag 不一致时仍按解析到的版本安装"
assert_grep 'v9.9.9/sing-box_9.9.9_openwrt_x86_64.apk' "$STUB_LOG" "下载地址采用解析到的版本"
assert_not_contains "$out" "已校验上游包 sha256" "不采信其它版本的 digest"
rm -f "$mismatch_json"

# 场景 C：解析与 API 都失败 → 交给调用方回退 feed
reset_case
STUB_EFFECTIVE="https://github.com/login" run_install >/dev/null 2>&1
assert_not_rc "$?" 0 "所有来源都失败时返回非 0（调用方回退 feed）"

# 场景 D：digest 不匹配 → 中止（不装坏包）
reset_case
digest_bad=$(mktemp)
printf '{"tag_name":"v9.9.9","assets":[{"name":"sing-box_9.9.9_openwrt_x86_64.apk","size":11,"digest":"sha256:deadbeef","browser_download_url":"https://example.test/download/v9.9.9/sing-box_9.9.9_openwrt_x86_64.apk"}]}\n' > "$digest_bad"
STUB_API_OK=1 STUB_JSON="$digest_bad" STUB_EFFECTIVE="https://github.com/SagerNet/sing-box/releases/tag/v9.9.9" \
    run_install >/dev/null 2>&1
assert_not_rc "$?" 0 "sha256 不符时中止安装"
rm -f "$digest_bad"

export PATH="$PATH_SAVED"
unset STUB_LOG STUB_VER_FILE STUB_ARCH
rm -rf "$stub" "$state" "$driver" "$fn_head" "$fn_body"

suite_end
