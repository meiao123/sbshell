#!/usr/bin/env bash
# 05_openwrt.sh
# 审计 P0-4 / P1-3.6 / P1-3.7 / P2-13 回归：OpenWrt 兼容性与开机防火墙恢复。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SCRIPTS=/etc/sing-box/scripts

suite_begin "openwrt: busybox grep has no -P, scripts must not rely on it (P1-3.6)"
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
cat > /etc/sing-box/defaults.conf <<'EOF'
TPROXY_TEMPLATE_URL=https://tpl.test/template.json
TUN_TEMPLATE_URL=https://tpl.test/template.json
EOF
fixture_write template.json "$VALID_CLIENT_CONFIG"
if grep -rn 'grep -oP' "$SBSHELL_SRC/openwrt" >/dev/null 2>&1; then fail "仍有脚本使用 grep -oP（busybox grep 不支持 PCRE）"; else pass "脚本没有使用 grep -oP"; fi
output=$(printf '\n\n\ny\n' | ( export PATH="$SBSHELL_FAKEBIN_BUSYBOX:$PATH"; run_with_timeout bash "$SCRIPTS/manual_input.sh" ) 2>&1)
rc=$?
assert_rc "$rc" 0 "在 busybox grep 环境下 manual_input.sh 成功"
assert_not_contains "$output" "未知的模式" "MODE 解析正确"
assert_file /etc/sing-box/config.json "配置已写入"

suite_begin "openwrt: initialize() must not swallow a failing step (P1-3.7)"
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
for f in "$SBSHELL_SRC"/openwrt/*.sh; do cp "$f" "$SBSHELL_FIXTURES/"; done
output=$(printf '\n' | SBSHELL_OPKG_FAIL=1 run_with_timeout bash "$SCRIPTS/menu.sh" 2>&1)
rc=$?
assert_not_rc "$rc" 0 "安装失败时初始化以非 0 结束"
init_path=$(sed -n 's/^INITIALIZED_FILE=//p' "$SBSHELL_SRC/openwrt/menu.sh" | head -n1)
init_path=${init_path//\"/}
init_path=${init_path//\$SCRIPT_DIR//etc/sing-box/scripts}
[ -n "$init_path" ] || init_path=/etc/sing-box/scripts/.initialized
if [ -f "$init_path" ]; then
    fail "安装失败却写入了 $init_path（旧代码 errexit 在函数内被关闭）"
else
    pass "失败时没有写入 $init_path"
fi

suite_begin "openwrt: autostart installs a boot-time firewall init script (P0-4)"
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
install_repo_scripts openwrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json
printf '1\n' | run_with_timeout bash "$SCRIPTS/manage_autostart.sh" >/tmp/autostart1.out 2>&1
rc=$?
assert_rc "$rc" 0 "启用自启动成功"
assert_file /etc/init.d/sbshell-firewall "生成 /etc/init.d/sbshell-firewall"
assert_grep 'apply_firewall' /etc/init.d/sbshell-firewall "开机脚本调用 apply_firewall"
assert_grep 'START=40' /etc/init.d/sbshell-firewall "开机脚本先于 sing-box (START=40)"
# 未加引号的 heredoc 不解释 `\t`。写错时开机脚本会去执行 `t/etc/...` 并以 127 失败，
# 重启后 nft 规则再也恢复不了（正是 P0-4 要防的静默失效）。
if grep -q '\\t' /etc/init.d/sbshell-firewall 2>/dev/null; then
    fail "开机脚本残留字面量 \\t（heredoc 不解释转义，执行时会 127）"
else
    pass "开机脚本没有转义残留"
fi
assert_grep "$SCRIPTS/manage_autostart.sh apply_firewall" /etc/init.d/sbshell-firewall "开机脚本直接调用 manage_autostart.sh apply_firewall"
if [ -e /etc/rc.d/S40sbshell-firewall ]; then pass "已注册开机启动链接"; else fail "未注册开机启动链接"; fi
if nft_table_exists sing-box; then pass "启用时已下发防火墙规则"; else fail "启用时未下发规则"; fi
rm -f "$SBSHELL_STUB_STATE/nft/inet__sing-box"
if nft_table_exists sing-box; then fail "模拟重启失败"; else pass "已模拟重启（规则丢失）"; fi
/etc/init.d/sbshell-firewall start >/tmp/autostart2.out 2>&1
assert_rc "$?" 0 "开机脚本执行成功"
if nft_table_exists sing-box; then pass "开机后规则被重新下发"; else fail "开机后规则仍未恢复"; fi
printf '2\n' | run_with_timeout bash "$SCRIPTS/manage_autostart.sh" >/tmp/autostart3.out 2>&1
assert_rc "$?" 0 "禁用自启动成功"
if [ -e /etc/rc.d/S40sbshell-firewall ]; then fail "开机启动链接未移除"; else pass "开机启动链接已移除"; fi

suite_begin "openwrt: TUN mode needs the tun module (P2-13)"
assert_grep 'kmod-tun' "$SBSHELL_SRC/openwrt/install_singbox.sh" "安装脚本尝试安装 kmod-tun"
assert_grep 'kmod-tun.*|| true' "$SBSHELL_SRC/openwrt/install_singbox.sh" "kmod-tun 安装失败不阻断"

suite_begin "openwrt: config privacy and self-update invariants"
assert_grep 'install -o root -g root -m 0600.*\$CONFIG_FILE' "$SBSHELL_SRC/openwrt/manual_update.sh" "manual_update config 为 0600"
assert_grep 'install -o root -g root -m 0600.*\$CONFIG_FILE' "$SBSHELL_SRC/openwrt/auto_update.sh" "auto_update config 为 0600"
assert_grep 'chmod 0600.*tmp_config' "$SBSHELL_SRC/openwrt/manual_input.sh" "manual_input 临时 config 为 0600"
assert_grep 'release_lock' "$SBSHELL_SRC/openwrt/manual_input.sh" "manual_input ownership-safe lock release"
assert_grep 'release_lock' "$SBSHELL_SRC/openwrt/manual_update.sh" "manual_update ownership-safe lock release"
assert_grep 'release_lock' "$SBSHELL_SRC/openwrt/auto_update.sh" "auto_update ownership-safe lock release"
assert_grep 'release_ui_lock' "$SBSHELL_SRC/openwrt/update_ui.sh" "interactive UI updater ownership-safe lock release"
assert_grep 'failed_ui=' "$SBSHELL_SRC/openwrt/update_ui.sh" "UI updater records failed deployment for rollback"
assert_grep 'mv "\$UI_DIR" "\$failed_ui"' "$SBSHELL_SRC/openwrt/update_ui.sh" "UI updater removes failed deployment before restoring backup"
assert_grep 'update_scripts.sh' "$SBSHELL_SRC/openwrt/update_scripts.sh" "updater 能更新自身"
assert_grep 'update_scripts.sh' "$SBSHELL_SRC/openwrt/menu.sh" "menu 保留自更新脚本"

suite_begin "openwrt: manual update requires HTTPS backend URLs (batch 1)"
assert_grep '\[\[ "\$1" =~ \^https://' "$SBSHELL_SRC/openwrt/manual_update.sh" "manual_update 只接受 HTTPS 后端地址"
assert_grep "proto '=https'" "$SBSHELL_SRC/openwrt/manual_update.sh" "manual_update curl 只允许 HTTPS"

suite_begin "openwrt: UI initialization and menu separator"
assert_grep "run update_ui.sh <<< '1'" "$SBSHELL_SRC/openwrt/menu.sh" "首次初始化自动安装默认 UI"
assert_grep '===============================================' "$SBSHELL_SRC/openwrt/menu.sh" "管理菜单提示前显示分隔线"
assert_no_grep 'rmdir "\$backup"' "$SBSHELL_SRC/openwrt/update_ui.sh" "首次安装 UI 时不再 rmdir 已删除的备份目录"

suite_begin "openwrt: uninstall menu behavior"
assert_grep "^    echo '11\. 卸载Sbshell'$" "$SBSHELL_SRC/openwrt/menu.sh" "卸载 Sbshell 选项使用与其他选项相同的颜色"
uninstall_block=$(sed -n '/^uninstall_sbshell()/,/^}/p' "$SBSHELL_SRC/openwrt/menu.sh")
confirm_count=$(printf '%s\n' "$uninstall_block" | grep -c '^[[:space:]]*confirm_yes ' || true)
assert_eq "$confirm_count" "1" "卸载 Sbshell 仅执行一次确认"
assert_no_grep '第二次确认：' "$SBSHELL_SRC/openwrt/menu.sh" "卸载流程移除第二次确认提示"

suite_begin "openwrt: startup, opkg lock and config download UX"
assert_grep 'mkdir -p /var/lock' "$SBSHELL_SRC/openwrt/install_singbox.sh" "opkg 操作前确保锁目录存在"
assert_grep 'run_opkg' "$SBSHELL_SRC/openwrt/install_singbox.sh" "opkg 调用统一过滤已知无害锁清理告警"
assert_grep 'opkg_conf_deinit.*opkg.lock' "$SBSHELL_SRC/openwrt/install_singbox.sh" "仅过滤 opkg.lock 清理告警"
assert_grep 'max-time 30' "$SBSHELL_SRC/openwrt/manual_input.sh" "配置下载超时为 30 秒"
assert_grep 'curl_pid=' "$SBSHELL_SRC/openwrt/manual_input.sh" "配置下载使用后台进程记录 PID"
assert_grep '配置文件下载中' "$SBSHELL_SRC/openwrt/manual_input.sh" "配置下载显示进度状态"
assert_grep '配置文件下载超时' "$SBSHELL_SRC/openwrt/manual_input.sh" "配置下载超时显示明确告警"
assert_grep 'ui_output=$(run update_ui.sh' "$SBSHELL_SRC/openwrt/menu.sh" "初始化 UI 安装期间暂存输出"
assert_grep 'printf.*tail -n1' "$SBSHELL_SRC/openwrt/menu.sh" "初始化 UI 完成后只显示最终通知"
assert_grep 'pidof sing-box' "$SBSHELL_SRC/openwrt/start_singbox.sh" "重复执行启动选项先检查 sing-box 状态"
assert_grep 'sing-box 已在运行，无需重复启动' "$SBSHELL_SRC/openwrt/start_singbox.sh" "sing-box 已运行时不重复应用防火墙"
assert_grep 'pidof sing-box' "$SBSHELL_SRC/openwrt/stop_singbox.sh" "停止前检查 sing-box 状态"
assert_grep 'sing-box 未运行，无需重复停止' "$SBSHELL_SRC/openwrt/stop_singbox.sh" "已停止时不重复调用服务"

suite_begin "openwrt: uninstall keeps cleanup moving when sing-box is a dependency"
assert_grep 'opkg remove sing-box' "$SBSHELL_SRC/openwrt/menu.sh" "卸载使用 OpenWrt opkg remove"
assert_grep '继续清理 Sbshell 文件' "$SBSHELL_SRC/openwrt/menu.sh" "sing-box 无法卸载时继续清理"
assert_grep 'rm -rf /etc/sing-box' "$SBSHELL_SRC/openwrt/menu.sh" "卸载时删除 sing-box 配置与脚本目录"
assert_grep 'sing-box 软件包当前无法卸载.*继续清理' "$SBSHELL_SRC/openwrt/menu.sh" "sing-box 卸载失败时只告警并继续"
assert_no_grep 'opkg remove --purge sing-box' "$SBSHELL_SRC/openwrt/menu.sh" "不再调用 OpenWrt 不支持的 --purge"
assert_grep '/etc/init.d/sing-box stop' "$SBSHELL_SRC/openwrt/menu.sh" "卸载前先请求停止 sing-box"
assert_grep 'pidof sing-box' "$SBSHELL_SRC/openwrt/clean_nft.sh" "防火墙清理前检查 sing-box 进程状态"
assert_grep 'sleep ' "$SBSHELL_SRC/openwrt/clean_nft.sh" "防火墙清理等待 sing-box 完全退出"

suite_begin "openwrt: autostart while sing-box is already running"
assert_grep 'pidof sing-box' "$SBSHELL_SRC/openwrt/manage_autostart.sh" "设置自启动前检查 sing-box 运行状态"
assert_grep '已在运行，跳过当前防火墙重载' "$SBSHELL_SRC/openwrt/manage_autostart.sh" "sing-box 运行时跳过重复防火墙应用"

suite_begin "openwrt: package-managed init script must be switched on through uci"
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
# 换成更接近真机的门控桩（复刻包里的 UCI 门控），并复刻包自带的 UCI 配置：enabled 0。
install -m 0755 "${SBSHELL_TEST_ROOT:-/opt/tests}/initd/sing-box-package" /etc/init.d/sing-box
mkdir -p "$SBSHELL_STUB_STATE/uci"
printf 'main - sing-box\nmain enabled 0\nmain conffile /etc/sing-box/config.json\n' > "$SBSHELL_STUB_STATE/uci/sing-box"
printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json
run_with_timeout /etc/init.d/sing-box start >/dev/null 2>&1
assert_rc "$?" 0 "上游风格脚本在 enabled=0 时 start 仍返回 0（静默不启动）"
if [ -e "$SBSHELL_STUB_STATE/singbox_active" ]; then fail "门控桩不该在没有 UCI 开关时启动进程"; else pass "门控桩忠实复刻了上游的静默不启动"; fi
export SBSHELL_INITD_NOISE=1
output=$(run_with_timeout bash "$SCRIPTS/install_singbox.sh" 2>&1)
rc=$?
unset SBSHELL_INITD_NOISE
assert_rc "$rc" 0 "install_singbox.sh 在包管理器脚本就位时成功"
assert_not_contains "$output" "Command failed" "初始化路径也把 ubus 噪音吃掉了（#!/bin/sh 用 mktemp+sed 写法）"
assert_eq "$(uci -q get sing-box.main.enabled)" "1" "install_singbox.sh 打开 sing-box.main.enabled"
if [ -e "$SBSHELL_STUB_STATE/singbox_active" ]; then pass "包管理器脚本真正启动了 sing-box"; else fail "sing-box 仍未启动：UCI 开关没生效（真机表现为「未运行，请检查日志」）"; fi
assert_grep 'sing-box.main.enabled=1' "$SBSHELL_SRC/openwrt/install_singbox.sh" "安装脚本显式打开包管理器服务的 UCI 开关"

suite_begin "openwrt: ubus 'Command failed' noise must not leak"
# rc.common/procd 在「没有已注册实例可删」时会回显 ubus 噪音，真机上见过两种形态：
#   短形态 `Command failed: Not found`
#   长形态 `Command failed: ubus call service delete { "name": "sing-box" } (Not found)`
# 旧写法 `'/^Command failed: Not found$/d'` 只压得住短形态，长形态会直接漏给用户（真机回归）。
NOISE_SED="sed '/^Command failed:\.\*Not found/d'"
for f in manual_update.sh auto_update.sh start_singbox.sh stop_singbox.sh menu.sh switch_mode.sh install_singbox.sh manage_autostart.sh; do
    assert_grep "$NOISE_SED" "$SBSHELL_SRC/openwrt/$f" "$f 用同一写法过滤两种噪音形态"
done
assert_no_grep 'Command failed: Not found\$' "$SBSHELL_SRC/openwrt/manual_update.sh" "不再只匹配整行等于短形态的旧写法"
assert_grep 'restart_singbox' "$SBSHELL_SRC/openwrt/auto_update.sh" "自动更新（#!/bin/sh）用可移植包装保留退出码"

suite_begin "openwrt: incompatible existing config must not abort initialization"
# 真机症状：路由器上残留的旧配置（例如 1.11 起废弃的 block/dns 特殊出站）让 `sing-box check`
# 返回非零，而预检写在 set -e 下，于是 install_singbox.sh 中止 → 初始化永远走不完、
# INITIALIZED_FILE 建不出来，菜单也进不去，用户只能看到 sing-box 自己那句 FATAL。
reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
install -m 0755 "${SBSHELL_TEST_ROOT:-/opt/tests}/initd/sing-box" /etc/init.d/sing-box
printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json

export SBSHELL_SINGBOX_CHECK_FAIL=1
run_with_timeout bash "$SCRIPTS/install_singbox.sh" >/tmp/is_check_fail.out 2>&1
rc=$?
unset SBSHELL_SINGBOX_CHECK_FAIL
assert_rc "$rc" 0 "现有配置未通过 check 时安装步骤仍然成功（不再拖垮整个初始化）"
if [ -e "$SBSHELL_STUB_STATE/singbox_active" ]; then fail "坏配置不该被拿去启动服务"; else pass "坏配置没有被拿去启动服务"; fi
assert_grep '未通过校验，已跳过启动 sing-box' /tmp/is_check_fail.out "明确告知已跳过启动"
assert_grep '手动更新配置' /tmp/is_check_fail.out "给出下一步操作指引"
# 真机日志（ImmortalWrt 25.12.2 + sing-box 1.12.25）：残留的旧配置会让 sing-box 打出
# WARN legacy DNS + ERROR legacy special outbounds + FATAL 三连。整段倒给用户只会让人
# 以为安装失败，所以只透出其中一行真正的原因。
assert_contains "$(cat /tmp/is_check_fail.out)" "ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS" "把真正的原因（FATAL 行）透出一行给用户"
assert_no_grep 'legacy DNS servers' /tmp/is_check_fail.out "不再把 sing-box 的 deprecation WARN 整段刷屏给用户"
assert_grep 'check_log=\$(mktemp' "$SBSHELL_SRC/openwrt/install_singbox.sh" "校验输出先收集、再筛出一行原因"
assert_grep 'reason=\$(grep -m1' "$SBSHELL_SRC/openwrt/install_singbox.sh" "失败原因优先取 FATAL 行"

printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json
run_with_timeout bash "$SCRIPTS/install_singbox.sh" >/tmp/is_check_ok.out 2>&1
assert_rc "$?" 0 "配置正常时安装步骤成功"
if [ -e "$SBSHELL_STUB_STATE/singbox_active" ]; then pass "配置正常时服务照旧被启动（无回归）"; else fail "配置正常时服务没有被启动"; fi
assert_grep 'if \[ -f /etc/sing-box/config.json \] && ! sing-box check' "$SBSHELL_SRC/openwrt/install_singbox.sh" "预检改为「失败不中止」的形式"
assert_grep '\[ "\$SKIP_RESTART" != 1 \]' "$SBSHELL_SRC/openwrt/install_singbox.sh" "预检失败时跳过重启服务"
assert_grep 'restart_err=$(mktemp /tmp/sbshell-restart.XXXXXX' "$SBSHELL_SRC/openwrt/install_singbox.sh" "#!/bin/sh 初始化路径用可移植写法保留 restart 退出码"

suite_begin "config_template: DNS servers use the sing-box 1.12+ form"
# 老式 `{"address": "tls://8.8.8.8"}` 在 1.12 会打 deprecation WARN，1.14 起彻底移除。
assert_grep '"type": "tls", "server": "8.8.8.8"' "$SBSHELL_SRC/config_template/config_tun.json" "加密 DNS 改用 type/server 新写法"
assert_no_grep '"address_strategy"' "$SBSHELL_SRC/config_template/config_tun.json" "不再使用已废弃的 address_strategy"
assert_no_grep '"address": "tls://' "$SBSHELL_SRC/config_template/config_tun.json" "不再使用老式 tls:// 地址写法"

suite_end
