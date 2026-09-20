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

# ---------------------------------------------------------------------------
# 真机复现（2026-09-11 ImmortalWrt）：菜单自动装完 UI 后报「UI 安装完成。」，但浏览器打开
# 面板是连接被拒 —— 因为 external_ui 由 sing-box 在**启动时**解析，运行中的实例不会挂载
# 后来才出现的目录；用户手动 /etc/init.d/sing-box restart 后面板才正常。
# 回归要求：装完必须探测面板、不可达就重启一次、仍不可达要明确告警而不是继续报成功。
# ---------------------------------------------------------------------------
suite_begin "update_ui: 装完必须确认面板真的在响应，不达则重启 sing-box（真机踩坑点）"

READY_SH=/tmp/ui12-ready.sh
DRIVER=/tmp/ui12-driver.sh
# 抽出探测/重启/通知三组函数（与 06 号套件抽 validate_archive 同一手法）。
awk '/^config_value\(\)/{p=1} /^install_ui\(\)/{p=0} p' "$SRC/update_ui.sh" > "$READY_SH"
cat > "$DRIVER" <<'EOS'
set -uo pipefail
UI_DIR=/etc/sing-box/ui
CONFIG_FILE=/etc/sing-box/config.json
SINGBOX_INITD=/etc/init.d/sing-box
GREEN=''; RED=''; YELLOW=''; NC=''
. /tmp/ui12-ready.sh
case "${1:-}" in
    url)   ui_panel_url; echo "url_rc=$?" ;;
    ready) notify_ui_ready ;;
esac
EOS

write_ui_config() {
    printf '{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9095","external_ui":"%s"}}}\n' "$1" > /etc/sing-box/config.json
}

# ① 面板有应答：不重启，报成功，并且探测的是配置里的端口与 /ui 路径
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
mkdir -p /etc/sing-box/ui
printf '<html></html>\n' > /etc/sing-box/ui/index.html
write_ui_config /etc/sing-box/ui
reset_fixtures
fixture_write index.html '<html>ok</html>'
touch "$SBSHELL_STUB_STATE/singbox_active"
UI_READY_OUT=$(run_with_timeout bash "$DRIVER" ready 2>&1); UI_READY_RC=$?

assert_rc "$UI_READY_RC" 0 "面板可达时收尾检查成功"
assert_contains "$UI_READY_OUT" "UI 安装完成。" "面板可达时报安装完成"
assert_not_contains "$UI_READY_OUT" "正在重启 sing-box" "面板可达时不重启 sing-box"
assert_grep '/ui/index.html' "$SBSHELL_STUB_STATE/curl.log" "探测地址取自配置的 external_controller 端口与 /ui 路径"
assert_eq "$(stub_log initd)" "" "面板可达时没有调用 init 脚本"

# ② 面板无应答 + sing-box 在运行：必须重启一次，并明确告警但仍不阻断（文件已装好）
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
mkdir -p /etc/sing-box/ui
printf '<html></html>\n' > /etc/sing-box/ui/index.html
write_ui_config /etc/sing-box/ui
reset_fixtures
touch "$SBSHELL_STUB_STATE/singbox_active"
UI_READY_OUT=$(run_with_timeout bash "$DRIVER" ready 2>&1); UI_READY_RC=$?

assert_rc "$UI_READY_RC" 0 "面板不可达不阻断安装（UI 文件已经装好）"
assert_contains "$UI_READY_OUT" "正在重启 sing-box" "面板不可达时主动重启 sing-box 以挂载 /ui"
# 真机（以及本夹具的 rc.common）里 `restart` 的语义是 stop 再 start，
# 所以断言这两步都发生，而不是去找字面量 "restart"。
assert_contains "$(stub_log initd)" "stop" "面板不可达时确实重启了服务（init 脚本收到 stop）"
assert_contains "$(stub_log initd)" "start" "重启会重新拉起 sing-box（init 脚本收到 start）"
assert_contains "$UI_READY_OUT" "但面板仍未响应" "重启后仍不可达要明确告警，而不是继续报成功"

# ③ sing-box 未运行：只提示，不擅自拉起服务
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
mkdir -p /etc/sing-box/ui
printf '<html></html>\n' > /etc/sing-box/ui/index.html
write_ui_config /etc/sing-box/ui
reset_fixtures
UI_READY_OUT=$(run_with_timeout bash "$DRIVER" ready 2>&1); UI_READY_RC=$?

assert_rc "$UI_READY_RC" 0 "sing-box 未运行时收尾检查不失败"
assert_contains "$UI_READY_OUT" "sing-box 当前未运行" "未运行时给出提示而不是偷偷启动服务"
assert_eq "$(stub_log initd)" "" "未运行时不去重启 sing-box"

# ④ external_ui 指向别的目录：面板不由我们负责，不重启
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
mkdir -p /etc/sing-box/ui
printf '<html></html>\n' > /etc/sing-box/ui/index.html
write_ui_config /opt/other-ui
reset_fixtures
touch "$SBSHELL_STUB_STATE/singbox_active"
UI_READY_OUT=$(run_with_timeout bash "$DRIVER" ready 2>&1); UI_READY_RC=$?

assert_rc "$UI_READY_RC" 0 "external_ui 不是本目录时收尾检查仍成功"
assert_contains "$UI_READY_OUT" "无法自动确认面板" "无法判定时如实说明，不谎称已确认"
assert_eq "$(stub_log initd)" "" "external_ui 指向别处时不得替用户重启 sing-box"

# ⑤ install_ui 的收尾必须走可达性通知；生成的 cron 版也要有同样的收尾检查
awk '/^install_ui\(\)/{p=1} p{print} p&&/^\}$/{exit}' "$SRC/update_ui.sh" > /tmp/ui12-install.sh
assert_grep 'notify_ui_ready' /tmp/ui12-install.sh "install_ui 收尾走「确认面板可达」的通知函数"
assert_grep 'panel_url()' "$SRC/update_ui.sh" "生成的 cron 自动更新脚本也探测面板"
assert_grep 'sing-box restart' "$SRC/update_ui.sh" "cron 版面板不可达时也会重启 sing-box"

# ⑥ A-06：服务在监听但**没有提供面板**（404/5xx）不能被当成"可达"。
# 真 curl 不带 --fail 时对 404 返回 0；旧实现只看 curl 退出码 → 判成可达、不重启，
# 用户看到"UI 安装完成"却打不开面板。夹具此前也把 404 建模成 exit 22，正好掩盖了它。
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
mkdir -p /etc/sing-box/ui
printf '<html></html>\n' > /etc/sing-box/ui/index.html
write_ui_config /etc/sing-box/ui
reset_fixtures
fixture_write index.html '<html>ok</html>'
touch "$SBSHELL_STUB_STATE/singbox_active"
UI_READY_OUT=$(run_with_timeout env SBSHELL_CURL_HTTP=404 bash "$DRIVER" ready 2>&1); UI_READY_RC=$?
assert_rc "$UI_READY_RC" 0 "面板返回 404 时收尾检查不阻断"
assert_contains "$UI_READY_OUT" "正在重启 sing-box" "只把 2xx 当可达：404 也必须重启一次"
assert_contains "$UI_READY_OUT" "404" "告警里要带真实 HTTP 状态码（便于定位）"
assert_contains "$(stub_log initd)" "stop" "404 时确实重启了服务"

# ⑥b 同一场景，但用"像真 curl 那样对 404 返回 0"的桩（SBSHELL_CURL_HTTP_REAL=1）
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
mkdir -p /etc/sing-box/ui
printf '<html></html>\n' > /etc/sing-box/ui/index.html
write_ui_config /etc/sing-box/ui
reset_fixtures
touch "$SBSHELL_STUB_STATE/singbox_active"
UI_READY_OUT=$(run_with_timeout env SBSHELL_CURL_HTTP=404 SBSHELL_CURL_HTTP_REAL=1 bash "$DRIVER" ready 2>&1)
assert_contains "$UI_READY_OUT" "正在重启 sing-box" "桩忠实模拟真 curl（404→rc 0）时仍必须重启"
assert_contains "$UI_READY_OUT" "404" "这种场景下同样要报出状态码"

# ⑦ A-05 固化：cron 版自动更新器读不到 config.json 时用内置默认下载地址（兜底本来就在）
assert_grep 'URL=${URL:-https://github.com/Zephyruso/zashboard/archive/15575961' "$SRC/update_ui.sh" \
    "cron 版 UI 更新器有内置默认下载地址兜底"
assert_grep 'UI_PANEL_HTTP_CODE' "$SRC/update_ui.sh" "面板探测区分「在监听但没提供面板」"

suite_end
