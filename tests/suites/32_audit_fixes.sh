#!/usr/bin/env bash
# 32_audit_fixes.sh
# 全量审计（x86_64 / ImmortalWrt 25.12.2 / apk + nftables）后的回归固化。
# 覆盖：菜单失败不退出、默认值显式空值语义、原子提交、cron 生成与 crontab 换行、
#       安装链路兜底与版本契约、配置解析、二级菜单、防火墙 IPv6/端口/锁/删除顺序。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SRC="${SBSHELL_SRC:-/src}"
O="$SRC/openwrt"
SCRIPTS=/etc/sing-box/scripts

suite_begin "P1-1：菜单里子脚本失败只提示并回到菜单"

assert_grep '^run_action() {' "$O/menu.sh" "menu.sh 定义 run_action"
assert_grep '^run() { bash "\$SCRIPT_DIR/\$1"; }$' "$O/menu.sh" "run() 保持严格（initialize 依赖失败传播）"
assert_grep 'esac || true' "$O/menu.sh" "菜单 case 失败不会带走整个交互菜单"
assert_eq "$(grep -c 'run_action ' "$O/menu.sh")" "10" "九个单步入口 + 选项 1 的三段串联"

suite_begin "P1-2：configure_tun 首次安装失败也要回收自己建的表"

assert_grep 'TUN_CREATED=1' "$O/configure_tun.sh" "记录本次新建的表"
assert_grep 'TUN_CREATED" -eq 1' "$O/configure_tun.sh" "回滚时按本次是否建表决策"
assert_no_grep '\[ "\$SNAPSHOTTED" -eq 1 \] || return 0' "$O/configure_tun.sh" "不再以“没有快照”为由跳过回收"

suite_begin "P1-3：缺 unzip 时包管理器输出不能混进 archive_top"

assert_grep '{ pkg_update && pkg_install unzip; } >/dev/null' "$O/update_ui.sh" "交互版 ensure_unzip 丢弃安装输出"
assert_grep 'ensure_unzip_auto' "$O/update_ui.sh" "cron 版仍保留（已有重定向）"

suite_begin "P1-4：TProxy 显式只代理 IPv4（v6 不再半代理）"

assert_eq "$(grep -c 'meta nfproto ipv6 return' "$O/configure_tproxy.sh")" "2" "两条链各一条 v6 放行"
assert_no_grep 'netbios-ssn' "$O/configure_tproxy.sh" "去掉永不匹配的 UDP netbios-ssn"
assert_grep 'tcp dport 139 accept' "$O/configure_tproxy.sh" "SMB(139/tcp) 单独放行"

suite_begin "P1-5：配置提交原子化 + 回滚依据本次备份"

assert_grep 'commit_file "\$TMP_DIR/config\.json" "\$CONFIG_FILE"' "$O/manual_update.sh" "config.json 走 lib 的原子提交（rename）"
assert_grep 'commit_file() {' "$O/lib.sh" "lib.sh 提供 commit_file 原子提交原语"
assert_grep 'config_existed' "$O/manual_update.sh" "回滚依据本次是否备份"
assert_grep 'commit_file "\$TMP_DIR/manual\.conf" "\$MANUAL_FILE"' "$O/manual_update.sh" "manual.conf 同样原子提交"
assert_grep 'mktemp /etc/sing-box/\.defaults\.conf\.' "$O/set_defaults.sh" "defaults.conf 原子提交（失败不再先删旧文件）"

suite_begin "P2：默认值显式空值语义（纯模板模式可用）"

assert_grep '"\$1=" "\$DEFAULTS_FILE"' "$O/lib.sh" "按键是否存在判断，而不是按键值非空（lib.sh）"
assert_grep 'resolve_default BACKEND_URL BACKEND_URL 1' "$O/manual_update.sh" "后端/订阅允许显式空值"
assert_grep 'resolve_default TPROXY_TEMPLATE_URL TEMPLATE_URL 0' "$O/manual_update.sh" "模板地址空值仍回退（空模板非法）"
assert_grep 'resolve_default' "$O/manual_input.sh" "初始化路径共用同一套默认值语义"
assert_grep 'if ! valid_url "\$TEMPLATE_URL"' "$O/manual_input.sh" "初始化路径也拒绝空模板（不再拼出 &file=）"

suite_begin "P2：mode.conf 缺失不再静默退出"

assert_grep 'MODE=\$( { sed -n ' "$O/manual_input.sh" "manual_input 吞掉 sed 失败"
assert_grep 'MODE=\$( { sed -n ' "$O/start_singbox.sh" "start_singbox 吞掉 sed 失败"

suite_begin "P2：下载上限与 cron 脚本原子生成"

assert_grep '--max-filesize 10485760' "$O/manual_update.sh" "选项 2 配置下载限额"
assert_grep '--max-filesize 10485760' "$O/manual_input.sh" "初始化配置下载限额"
assert_grep '--max-filesize 10485760' "$O/auto_update.sh" "cron 配置下载限额"
assert_grep 'UPDATE_SCRIPT_TMP' "$O/auto_update.sh" "cron 脚本先写临时文件"
assert_grep 'sh -n "\$UPDATE_SCRIPT_TMP"' "$O/auto_update.sh" "安装前语法自检"
assert_grep 'tail -c 1 "\$CRON_FILE"' "$O/auto_update.sh" "crontab 追加前补行尾换行"
assert_grep 'tail -c 1 "\$CRON_FILE"' "$O/update_ui.sh" "UI cron 同样补行尾换行"

suite_begin "P2：安装链路兜底 + 版本契约 + 服务实检"

assert_grep 'run_opkg update ||' "$O/install_singbox.sh" "索引刷新失败不阻断初始化"
assert_grep 'kmod-nft-tproxy ||' "$O/install_singbox.sh" "TProxy 依赖失败不阻断 TUN 用户"
assert_grep 'modprobe tun' "$O/install_singbox.sh" "装完 kmod-tun 主动尝试加载"
assert_grep '要求 sing-box 1.14+' "$O/install_singbox.sh" "feed 1.12.x 与 1.14 模板的版本契约告警"
assert_grep 'pidof sing-box' "$O/install_singbox.sh" "restart 返回 0 后仍实检进程"
assert_grep "exit 130' INT TERM" "$O/install_singbox.sh" "Ctrl+C 真的中止安装"

suite_begin "P2：UCI 门控与自启动实检"

assert_grep 'sing-box.main.enabled=1' "$O/manage_autostart.sh" "菜单 7 也打开 UCI 开关"
assert_grep 'pidof sing-box' "$O/manage_autostart.sh" "启动后实检进程"

suite_begin "P2：check_config 按花括号配对取 api 对象"

assert_grep 'api_range=\$(awk' "$O/check_config.sh" "不再用 sed 的“首个 }”范围"
assert_grep 'api_block=\$(sed -n' "$O/check_config.sh" "仍复用原有解析"

suite_begin "P2：告警/退出码语义"

assert_grep '未找到 nft' "$O/check_environment.sh" "缺 nft 的通道保留"
assert_grep 'exit 1' "$O/check_environment.sh" "缺 nft 时初始化应被拦住"
assert_grep '检测到 sing-box 未运行，是否清理残留防火墙规则' "$O/stop_singbox.sh" "崩溃残留可清理"
assert_grep '保留防火墙规则会让本机出站被代理规则拦截' "$O/stop_singbox.sh" "停止但不清理时给出后果提示"
assert_grep '/etc/init.d/sing-box start' "$O/switch_mode.sh" "切换失败回滚时尝试恢复服务"

suite_begin "P2：防火墙并发锁与删除顺序"

assert_eq "$(grep -c 'flock -w 20 9' "$O/configure_tproxy.sh" "$O/configure_tun.sh" "$O/clean_nft.sh" | awk -F: '{s+=$2} END {print s}')" "3" "三条变更路径共用一把锁"
assert_grep 'keep_state' "$O/clean_nft.sh" "先删表时保留 state 给路由清理用"
tbl_line=$(grep -n 'clean_owned_table sing-box "\$TPROXY_STATE_FILE"' "$O/clean_nft.sh" | head -n1 | cut -d: -f1)
route_line=$(grep -n '^clean_tproxy_routes || exit 1$' "$O/clean_nft.sh" | head -n1 | cut -d: -f1)
if [ -n "$tbl_line" ] && [ -n "$route_line" ] && [ "$tbl_line" -lt "$route_line" ]; then
    pass "删除顺序：先删表、后删策略路由"
else
    fail "删除顺序不对（表=$tbl_line 路由=$route_line）"
fi

suite_begin "P2：二级菜单每次重新打印、EOF 不死循环（行为）"

reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
out=$(printf '1\n\n0\n' | run_with_timeout bash "$SCRIPTS/commands.sh" 2>&1)
menus=$(printf '%s\n' "$out" | grep -c '二级菜单选项')
if [ "$menus" -ge 2 ]; then pass "操作后菜单重新打印（$menus 次）"; else fail "菜单只打印 $menus 次"; fi
out2=$(printf '' | run_with_timeout bash "$SCRIPTS/commands.sh" 2>&1)
rc2=$?
assert_rc "$rc2" 0 "stdin EOF 时正常退出"
spins=$(printf '%s\n' "$out2" | grep -c '无效的选择')
if [ "$spins" -le 1 ]; then pass "EOF 不再无限刷“无效的选择”（$spins 次）"; else fail "EOF 仍死循环（$spins 次）"; fi

suite_begin "P2：TProxy 端口以 config.json 为准（行为）"

reset_stub_state
reset_singbox_dir
install_repo_scripts openwrt
printf 'MODE=TProxy\n' > /etc/sing-box/mode.conf
cat > /etc/sing-box/config.json <<'EOF'
{"inbounds":[{"type":"tproxy","tag":"tproxy-in","listen":"0.0.0.0","listen_port":1080}],"outbounds":[]}
EOF
run_with_timeout bash "$SCRIPTS/configure_tproxy.sh" >/tmp/a32-tproxy.out 2>&1
assert_rc "$?" 0 "按 config.json 的端口下发规则成功"
assert_grep 'tproxy to :1080' "$SBSHELL_STUB_STATE/nft/inet__sing-box" "规则使用 config.json 里的 1080"
assert_no_grep 'tproxy to :7895' "$SBSHELL_STUB_STATE/nft/inet__sing-box" "不再写死 7895"

suite_end
