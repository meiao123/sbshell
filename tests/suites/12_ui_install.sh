#!/usr/bin/env bash
# 12_ui_install.sh
# 真机需求回归：
#   ① 安装流程必须主动安装默认 UI —— 即使配置下载/启动失败，UI 也要装上
#   ② UI 安装完成的通知（或失败警告）必须先于主菜单出现，且 UI 失败不能挡住菜单
#   ③ 配置下载/更新统一 30s 超时并显示倒计时（manual_update.sh、auto_update.sh 的 cron 脚本）
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SRC="$SBSHELL_SRC/openwrt"

# menu.sh 的 SCRIPT_DIR 固定是 /etc/sing-box/scripts，初始化第一步又是自更新（会把仓库里的
# 全部脚本重新下载、覆盖该目录）。所以：
#   * 主菜单从 $SCRIPT_DIR 之外的一份副本运行，避免自更新把「正在运行的脚本」就地覆盖；
#   * 各步骤脚本用桩放进 $SCRIPT_DIR（并同时写进 fixtures，让自更新也能成功装上桩），
#     这样整个过程完全不需要联网，还能观察到调用顺序。
SCRIPTS_LIST='check_environment.sh install_singbox.sh manual_input.sh manual_update.sh auto_update.sh configure_tproxy.sh configure_tun.sh start_singbox.sh stop_singbox.sh clean_nft.sh set_defaults.sh commands.sh switch_mode.sh manage_autostart.sh check_config.sh update_scripts.sh update_ui.sh menu.sh'

STUB_BODY='#!/bin/bash
name=$(basename "$0" .sh)
printf "%s\n" "$name" >> "${STUB_ORDER:?}"
var="STUB_RC_$(printf "%s" "$name" | tr "[:lower:]" "[:upper:]")"
eval "rc=\${$var:-0}"
if [ "$name" = update_ui ]; then
    if [ "$rc" = 0 ]; then
        mkdir -p /etc/sing-box/ui
        printf "<html></html>\n" > /etc/sing-box/ui/index.html
        echo "UI 安装完成。"
        exit 0
    fi
    echo "UI 压缩包下载失败。" >&2
fi
exit "$rc"'

# 主菜单副本目录（$SCRIPT_DIR 之外）
MENU_RUN_DIR=$(mktemp -d /tmp/sbshell-menu.XXXXXX)
install_menu_copy() { install -m 0755 "$SRC/menu.sh" "$MENU_RUN_DIR/menu.sh"; }

install_stub_scripts() {
    local s
    mkdir -p /etc/sing-box/scripts
    for s in $SCRIPTS_LIST; do
        [ "$s" = menu.sh ] && continue
        printf '%s\n' "$STUB_BODY" > "/etc/sing-box/scripts/$s"
        chmod 0755 "/etc/sing-box/scripts/$s"
    done
    install -m 0755 "$SRC/menu.sh" /etc/sing-box/scripts/menu.sh
}

install_stub_fixtures() {
    local s
    reset_fixtures
    for s in $SCRIPTS_LIST; do
        if [ "$s" = menu.sh ]; then
            # menu.sh 自身不换成桩（否则自更新会把主菜单覆盖成桩），给一份合法的最小脚本
            # 让它通过 bash -n 校验即可。
            fixture_write "$s" '#!/bin/bash
exit 0'
        else
            fixture_write "$s" "$STUB_BODY"
        fi
    done
}

order_file() { ORDER_FILE=$(mktemp /tmp/sbshell-order.XXXXXX); : > "$ORDER_FILE"; }
order_list() { tr '\n' ' ' < "$ORDER_FILE"; }

# 跑一次 menu.sh：$1 = 喂给 stdin 的内容
run_menu() {
    MENU_OUT=$(printf '%b' "$1" | run_with_timeout env "STUB_ORDER=$ORDER_FILE" bash "$MENU_RUN_DIR/menu.sh" 2>&1)
    MENU_RC=$?
}

install_menu_copy

suite_begin "menu.sh 初始化：先装 UI 再进配置输入，且都先于主菜单（需求 ①②）"

reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
install_stub_fixtures
order_file
run_menu '\n0\n'

assert_rc "$MENU_RC" 0 "初始化成功并进入菜单"
assert_eq "$(order_list)" "check_environment install_singbox update_ui switch_mode manual_input start_singbox " "初始化顺序：装完 sing-box 立刻装 UI，然后才是模式选择与配置输入"
assert_contains "$MENU_OUT" "UI 安装完成。" "UI 安装完成通知已打印"
assert_contains "${MENU_OUT%%Sbshell OpenWrt 管理菜单*}" "UI 安装完成。" "通知先于主菜单出现"
assert_contains "$MENU_OUT" "Sbshell OpenWrt 管理菜单" "通知之后才弹出主菜单"

suite_begin "menu.sh 初始化：UI 安装失败也要给警告并照常弹菜单（需求 ②）"

reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
install_stub_fixtures
order_file
MENU_OUT=$(printf '\n0\n' | run_with_timeout env "STUB_ORDER=$ORDER_FILE" STUB_RC_UPDATE_UI=1 bash "$MENU_RUN_DIR/menu.sh" 2>&1)
MENU_RC=$?

assert_rc "$MENU_RC" 0 "UI 安装失败不影响初始化结果"
assert_contains "$MENU_OUT" "警告：默认 UI 安装失败" "UI 失败时给出黄字警告"
assert_contains "$MENU_OUT" "UI 压缩包下载失败。" "把 UI 失败原因透传给用户"
assert_contains "$MENU_OUT" "Sbshell OpenWrt 管理菜单" "UI 失败后仍然弹出菜单"

suite_begin "menu.sh 初始化：配置下载失败时 UI 仍必须被安装（需求 ①，真机踩坑点）"

reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
install_stub_fixtures
order_file
MENU_OUT=$(printf '\n0\n' | run_with_timeout env "STUB_ORDER=$ORDER_FILE" STUB_RC_MANUAL_INPUT=1 bash "$MENU_RUN_DIR/menu.sh" 2>&1)
MENU_RC=$?

assert_not_rc "$MENU_RC" 0 "配置下载失败仍按原语义中止初始化"
assert_grep '^update_ui$' "$ORDER_FILE" "UI 在配置下载失败之前就已经装上了（旧代码这里永远装不上）"
assert_contains "$MENU_OUT" "UI 安装完成。" "配置失败场景下 UI 通知照常打印"

suite_begin "menu.sh 输入 skip：跳过初始化也要把 UI 装上（需求 ①）"

reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
install_stub_fixtures
order_file
run_menu 'skip\n0\n'

assert_rc "$MENU_RC" 0 "skip 后直接进菜单"
assert_eq "$(order_list)" "update_ui " "skip 跳过初始化时 UI 仍被安装（旧代码这条路径永远不装 UI）"
assert_contains "$MENU_OUT" "Sbshell OpenWrt 管理菜单" "菜单正常弹出"

suite_begin "menu.sh 已初始化：缺 UI 时进菜单前自动补装（需求 ①）"

reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
install_stub_scripts
touch /etc/sing-box/scripts/.initialized
order_file
run_menu '0\n'

assert_rc "$MENU_RC" 0 "已初始化的机器直接进菜单"
assert_eq "$(order_list)" "update_ui " "发现 UI 缺失时自动补装一次"
assert_contains "$MENU_OUT" "UI 安装完成。" "补装后给出完成通知"

suite_begin "menu.sh 已初始化：UI 已存在时不重复下载（需求 ①②）"

reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
install_stub_scripts
mkdir -p /etc/sing-box/ui
printf '<html></html>\n' > /etc/sing-box/ui/index.html
touch /etc/sing-box/scripts/.initialized
order_file
run_menu '0\n'

assert_rc "$MENU_RC" 0 "已安装 UI 的机器直接进菜单"
assert_eq "$(wc -l < "$ORDER_FILE" | tr -d ' ')" "0" "UI 已存在时不重复下载"
assert_not_contains "$MENU_OUT" "正在安装默认 UI" "已装好时不再提示安装"
assert_contains "$MENU_OUT" "Sbshell OpenWrt 管理菜单" "菜单正常弹出"

suite_begin "配置下载/更新：统一 30s 超时 + 倒计时（需求 ③）"

assert_grep '配置文件下载中，超时倒计时: %02ds' "$SRC/manual_input.sh" "初始化下载仍显示倒计时（不回归）"
assert_grep '配置文件下载中，超时倒计时: %02ds' "$SRC/manual_update.sh" "手动更新配置显示倒计时"
assert_grep '--max-time 30' "$SRC/manual_update.sh" "手动更新超时为 30s"
assert_no_grep '--max-time 60' "$SRC/manual_update.sh" "手动更新不再用 60s"
assert_grep '新配置下载超时（30s）' "$SRC/manual_update.sh" "手动更新超时有明确提示"
assert_grep '配置文件下载中，超时倒计时: %02ds' "$SRC/auto_update.sh" "cron 自动更新脚本也显示倒计时"
assert_grep 'if \[ -t 1 \]' "$SRC/auto_update.sh" "cron 下静默：仅在终端打印倒计时"
assert_grep '--max-time 30' "$SRC/auto_update.sh" "自动更新超时为 30s"
assert_grep '下载超时（30s）' "$SRC/auto_update.sh" "自动更新超时有明确提示"

suite_end
