#!/usr/bin/env bash
# 10_package_manager.sh
# 真机回归（ImmortalWrt 25.12.2 / x86_64 / apk-tools 3.0.5）：OpenWrt 25.12 起用 apk
# 取代了 opkg（ImmortalWrt 25.x 同源）。旧脚本只认 opkg，于是初始化在第一步就中止，
# 真机日志只有两行，看不出原因：
#   sing-box 已安装，版本：1.12.25
#   仅支持 OpenWrt。
# 这里构造「PATH 里没有 opkg、只有 apk」的固件环境，验证四个调用点都改走 apk；
# 同时保证老固件（只有 opkg）的调用序列逐条不变。
#   * openwrt/install_singbox.sh  装依赖（一键引导里最先撞上的一处）
#   * openwrt/update_ui.sh        缺 unzip/zipinfo 时装依赖（set -e 下会整个中止）
#   * sbshall.sh                  引导脚本把 curl/bash/nft 装回来
#   * openwrt/menu.sh             卸载时移除 sing-box 软件包
#
# 注意：all.sh 会导出 SBSHELL_FAKEBIN / SBSHELL_TEST_ROOT，单独跑本套件时未必有，
# 两处都带默认值，避免 set -u 下因未绑定变量退出。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SCRIPTS=/etc/sing-box/scripts
APK_LOG="$SBSHELL_STUB_STATE/apk.log"
OPKG_LOG="$SBSHELL_STUB_STATE/opkg.log"

# 构造一个 PATH：链接当前 PATH 里的全部可执行文件，但排除 opkg（模拟 apk-only 固件）
# 与 unzip/zipinfo（模拟缺解压工具的固件）。fakebin 在最前面，因此 apk 桩会被链进来。
path_without() {
    local out p f b
    out=$(mktemp -d)
    for p in $(printf '%s' "$PATH" | tr ':' '\n'); do
        [ -d "$p" ] || continue
        for f in "$p"/*; do
            [ -f "$f" ] || continue
            b=${f##*/}
            b=${b%.exe}                 # MSYS/Cygwin 上真名可能带 .exe
            case "$b" in opkg|unzip|zipinfo) continue ;; esac
            [ -e "$out/$b" ] || ln -s "$f" "$out/$b" 2>/dev/null || true
        done
    done
    printf '%s' "$out"
}

# 只有 sing-box 桩的目录：用来模拟「既没有 opkg 也没有 apk」的系统。
make_bare_bin() {
    local root=${SBSHELL_TEST_ROOT:-/opt/tests} dir
    dir=$(mktemp -d) || return 1
    cp "$root/fakebin/sing-box" "$dir/sing-box" 2>/dev/null || true
    chmod 0755 "$dir/sing-box" 2>/dev/null || true
    printf '%s' "$dir"
}

APKONLY=$(path_without)
NO_PKG_MGR_PATH="$(make_bare_bin):/usr/bin:/bin"

# 先自证环境构造有效，否则后面的断言没有意义。
if (PATH="$APKONLY" command -v opkg >/dev/null 2>&1); then
    fail "测试环境构造失败：受限 PATH 里仍能看到 opkg"
elif (PATH="$APKONLY" command -v apk >/dev/null 2>&1); then
    pass "受限 PATH 里没有 opkg、有 apk（模拟 OpenWrt 25.12+ 固件）"
else
    fail "受限 PATH 丢了 apk 桩"
fi

suite_begin "openwrt: install_singbox.sh installs through apk on OpenWrt 25.12+ firmware"
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json
rm -f "$APK_LOG" "$OPKG_LOG"
out=$(PATH="$APKONLY" run_with_timeout bash "$SCRIPTS/install_singbox.sh" 2>&1); rc=$?
assert_rc "$rc" 0 "apk 固件上安装脚本成功（不再中止初始化）"
assert_not_contains "$out" "仅支持 OpenWrt" "不再误报「仅支持 OpenWrt。」"
assert_grep '^apk update$' "$APK_LOG" "用 apk update 刷新索引"
assert_grep '^apk add kmod-nft-tproxy sing-box$' "$APK_LOG" "用 apk add 安装依赖"
assert_grep '^apk add kmod-tun$' "$APK_LOG" "用 apk add 安装 kmod-tun（TUN 模式）"
assert_no_grep '^opkg ' "$OPKG_LOG" "apk 固件上不调用 opkg"
assert_file /etc/init.d/sing-box "apk 固件上 init 脚本仍在位"

suite_begin "openwrt: opkg firmware keeps the exact same opkg call sequence (no regression)"
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json
rm -f "$APK_LOG" "$OPKG_LOG"
out=$(run_with_timeout bash "$SCRIPTS/install_singbox.sh" 2>&1); rc=$?
assert_rc "$rc" 0 "opkg 固件上安装脚本成功"
assert_grep '^opkg update$' "$OPKG_LOG" "老固件仍用 opkg update"
assert_grep '^opkg install kmod-nft-tproxy sing-box$' "$OPKG_LOG" "老固件仍用 opkg install"
assert_grep '^opkg install kmod-tun$' "$OPKG_LOG" "老固件仍用 opkg install kmod-tun"
assert_no_file "$APK_LOG" "老固件不会调用 apk"

suite_begin "openwrt: update_ui.sh 只在真正解析压缩包时才按需装 unzip（A-13）"
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
if (PATH="$APKONLY" command -v unzip >/dev/null 2>&1); then
    fail "测试环境构造失败：受限 PATH 里仍能看到 unzip"
else
    pass "受限 PATH 里没有 unzip/zipinfo（模拟缺解压工具的固件）"
fi

# ① 入口不再探测/安装依赖：依赖齐全时进入脚本不得调用任何包管理器
#    （旧代码顶层无条件探测 zipinfo → 每次进菜单都可能先跑一次 opkg update）。
rm -f "$APK_LOG" "$OPKG_LOG"
out=$(printf '0\n' | run_with_timeout bash "$SCRIPTS/update_ui.sh" 2>&1); rc=$?
assert_not_contains "$out" "command not found" "缺 opkg 的设备上不再直接中止"
assert_no_file "$APK_LOG" "依赖齐全时进入脚本不触发 apk 安装"
assert_no_file "$OPKG_LOG" "依赖齐全时进入脚本不触发 opkg 安装"
assert_not_rc "$rc" 127 "退出码不是 127（旧代码 opkg 缺失时的 command not found）"

# ② 真正解析压缩包且缺 unzip 时才安装：抽出 ensure_unzip + validate_archive 驱动一次。
#    受限 PATH 里 apk 只是桩（不会真的装），因此装完仍缺 unzip，必须 fail-closed。
rm -rf /tmp/ui10-src; mkdir -p /tmp/ui10-src
printf '<html></html>\n' > /tmp/ui10-src/index.html
rm -f /tmp/ui10-real.zip
(cd /tmp/ui10-src && zip -q /tmp/ui10-real.zip index.html)
awk '/^ensure_unzip\(\)/{p=1} p{print} p&&/^\}$/{exit}' "$SCRIPTS/update_ui.sh" > /tmp/ui10-va.sh
awk '/^validate_archive\(\)/{p=1} p{print} p&&/^\}$/{exit}' "$SCRIPTS/update_ui.sh" >> /tmp/ui10-va.sh
rm -f "$APK_LOG" "$OPKG_LOG"
PATH="$APKONLY" run_with_timeout bash -c '
    pkg_update() { apk update; }
    pkg_install() { apk add "$@"; }
    RED=""; NC=""
    . /tmp/ui10-va.sh
    validate_archive /tmp/ui10-real.zip' > /tmp/ui10-va.out 2>&1; rc=$?
assert_grep '^apk add unzip$' "$APK_LOG" "缺 unzip 时才通过 apk 安装 unzip"
assert_grep '缺少 unzip' /tmp/ui10-va.out "装不上时 fail-closed，并说明缺的是 unzip"
assert_grep 'ensure_unzip_auto' "$SBSHELL_SRC/openwrt/update_ui.sh" "cron 生成体也会自己装 unzip（否则缺 unzip 的设备上自动更新永久失败）"
assert_not_rc "$rc" 0 "受限 PATH 里装不上 unzip 时必须拒绝（fail-closed）"

suite_begin "bootstrap: sbshall.sh install_package supports apk"
awk '/^# 修复点 2/{p=1} p{print} p&&/^}$/{exit}' "$SBSHELL_SRC/sbshall.sh" > /tmp/sbshell-bootstrap-pkg.sh
if grep -q '^install_package()' /tmp/sbshell-bootstrap-pkg.sh; then
    pass "抽到 sbshall.sh 的包管理器分派 + install_package"
else
    fail "抽不到 install_package（实现变了？）"
fi
cat > /tmp/sbshell-bootstrap-probe.sh <<'EOS'
set -Eeuo pipefail
RED=''; GREEN=''; CYAN=''; YELLOW=''; NC=''
is_openwrt=true
. /tmp/sbshell-bootstrap-pkg.sh
rc=0
install_package "$1" || rc=$?
exit "$rc"
EOS
rm -f "$APK_LOG" "$OPKG_LOG"
out=$(PATH="$APKONLY" run_with_timeout bash /tmp/sbshell-bootstrap-probe.sh bash 2>&1); rc=$?
assert_rc "$rc" 0 "apk 固件上 install_package 成功"
assert_grep '^apk update$' "$APK_LOG" "引导脚本用 apk update 刷新索引"
assert_grep '^apk add bash$' "$APK_LOG" "引导脚本用 apk add 装依赖"
rm -f "$APK_LOG" "$OPKG_LOG"
out=$(run_with_timeout bash /tmp/sbshell-bootstrap-probe.sh bash 2>&1); rc=$?
assert_rc "$rc" 0 "opkg 固件上 install_package 成功"
assert_grep '^opkg update$' "$OPKG_LOG" "引导脚本在 opkg 固件上仍用 opkg update"
assert_grep '^opkg install bash$' "$OPKG_LOG" "引导脚本在 opkg 固件上仍用 opkg install"
assert_no_file "$APK_LOG" "opkg 固件上不调用 apk"

suite_begin "bootstrap: no package manager must fail loudly and name the problem"
rm -f "$APK_LOG" "$OPKG_LOG"
out=$(PATH="$NO_PKG_MGR_PATH" run_with_timeout bash /tmp/sbshell-bootstrap-probe.sh bash 2>&1); rc=$?
assert_not_rc "$rc" 0 "既没有 opkg 也没有 apk 时以非 0 结束"
assert_contains "$out" "未找到 opkg 或 apk" "提示里说明缺的是包管理器"

suite_begin "openwrt: uninstall removes the sing-box package with the available manager"
assert_grep 'opkg remove sing-box' "$SBSHELL_SRC/openwrt/menu.sh" "opkg 固件仍用 opkg remove"
assert_grep 'apk del sing-box' "$SBSHELL_SRC/openwrt/menu.sh" "apk 固件用 apk del"
assert_no_grep 'opkg remove --purge sing-box' "$SBSHELL_SRC/openwrt/menu.sh" "不引入 OpenWrt 不支持的 --purge"

suite_end
