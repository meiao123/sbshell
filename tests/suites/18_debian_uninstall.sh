#!/usr/bin/env bash
# 18_debian_uninstall.sh —— 批次 3 补：Debian 侧卸载路径的行为覆盖。
#
# Debian 的 uninstall_sbshell 与 OpenWrt 语义**不同**，必须单独覆盖：
#   * 只删 Sbshell 管理脚本与快捷方式，**保留** sing-box 程序与 /etc/sing-box 配置
#   * 两步确认（第一次与第二次都要问到，任一步回答 n 都必须原地不动）
#   * 清理 /root/.bashrc 里的快捷方式块，但保留其它内容
#
# 这里把 debian/menu.sh 的真实 confirm_yes 与 uninstall_sbshell **原样抽出**执行。
# 第 4 个场景专门回归 confirm_yes 的 EOF 修复：旧实现 `read` 失败不处理，函数又在 `||`
# 上下文里（errexit 失效），空答案反复命中 `*)` 分支 → 100% CPU 死循环（实测 2 秒 13 万行）。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

MENU="$SBSHELL_SRC/debian/menu.sh"
SCRIPT_DIR=/etc/sing-box/scripts

# 从真实脚本里取值，避免在测试里复制它们的取值；同时去掉引号并把 $SCRIPT_DIR 展开成
# 真实路径（否则夹具会创建名为 "$SCRIPT_DIR/.initialized" 的字面量文件，断言变成空转）。
INITIALIZED_FILE=$(sed -n 's/^INITIALIZED_FILE=//p' "$MENU" | head -n1 | tr -d '"' | sed "s|\$SCRIPT_DIR|$SCRIPT_DIR|g")
ROLE_FILE=$(sed -n 's/^ROLE_FILE=//p' "$MENU" | head -n1 | tr -d '"' | sed "s|\$SCRIPT_DIR|$SCRIPT_DIR|g")
assert_grep '^INITIALIZED_FILE=' "$MENU" "menu.sh 定义了 INITIALIZED_FILE"
assert_grep '^ROLE_FILE=' "$MENU" "menu.sh 定义了 ROLE_FILE"
case "$INITIALIZED_FILE" in
    /*) pass "INITIALIZED_FILE 解析为绝对路径（$INITIALIZED_FILE）" ;;
    *) fail "INITIALIZED_FILE 未解析出绝对路径（got '$INITIALIZED_FILE'）" ;;
esac
case "$ROLE_FILE" in
    /*) pass "ROLE_FILE 解析为绝对路径（$ROLE_FILE）" ;;
    *) fail "ROLE_FILE 未解析出绝对路径（got '$ROLE_FILE'）" ;;
esac

awk '/^confirm_yes\(\)/{p=1} p{print} p&&/^\}$/{exit}' "$MENU" > /tmp/u18-confirm.sh
awk '/^uninstall_sbshell\(\)/{p=1} p{print} p&&/^\}$/{exit}' "$MENU" > /tmp/u18-uninstall.sh
assert_grep 'confirm_yes' /tmp/u18-confirm.sh "抽到 confirm_yes 函数体"
assert_grep 'uninstall_sbshell' /tmp/u18-uninstall.sh "抽到 uninstall_sbshell 函数体"

# 抽出的函数体依赖 menu.sh 顶部的颜色变量与这两个文件变量，这里按 menu.sh 的定义补齐。
cat > /tmp/u18-driver.sh <<EOS
set -uo pipefail
RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
SCRIPT_DIR=$SCRIPT_DIR
INITIALIZED_FILE=$INITIALIZED_FILE
ROLE_FILE=$ROLE_FILE
. /tmp/u18-confirm.sh
. /tmp/u18-uninstall.sh
uninstall_sbshell
EOS

setup_uninstall_case() {
    reset_singbox_dir
    install_repo_scripts debian
    reset_stub_state
    mkdir -p /etc/cron.d /usr/local/bin /root
    : > /etc/cron.d/sbshell-ui
    : > /etc/cron.d/sbshell-singbox
    : > /usr/local/bin/sb
    : > /etc/sing-box/update-ui.sh
    : > /etc/sing-box/update-singbox.sh
    : > "$INITIALIZED_FILE"
    : > "$ROLE_FILE"
    printf 'export PATH=$PATH:/usr/local/bin\n# sing-box 快捷方式\nalias sb=%s/menu.sh\nkeep-me\n' "$SCRIPT_DIR" > /root/.bashrc
}

# stdin 走文件、`timeout -k` 兜底：既避免管道等待，也保证任何路径挂住时最多 20 秒。
run_uninstall() {
    local rc=0
    printf '%b' "$1" > /tmp/u18.in
    timeout -k 5 20 bash /tmp/u18-driver.sh < /tmp/u18.in > /tmp/u18.out 2>&1 || rc=$?
    return "$rc"
}

# ------------------------------------------------------ 1) 第一次确认回答 n
suite_begin "debian uninstall: 第一次确认回答 n 时不得改动任何东西"
setup_uninstall_case
run_uninstall 'n\n'; rc=$?
out=$(cat /tmp/u18.out)
assert_contains "$out" "已取消卸载" "第一次确认回答 n 时提示已取消"
assert_not_rc "$rc" 124 "取消路径没有挂住（未被超时杀掉）"
assert_rc "$rc" 0 "取消卸载返回 0"
assert_file "$SCRIPT_DIR/menu.sh" "取消后脚本目录仍在"
assert_file /usr/local/bin/sb "取消后快捷方式仍在"
assert_file "$INITIALIZED_FILE" "取消后初始化标记仍在"

# ------------------------------------------------------ 2) 第二次确认回答 n
suite_begin "debian uninstall: 第二次确认回答 n 时必须原地不动"
setup_uninstall_case
run_uninstall 'y\nn\n'; rc=$?
out=$(cat /tmp/u18.out)
assert_contains "$out" "已取消卸载" "第二次确认回答 n 时提示已取消"
assert_rc "$rc" 0 "第二次取消返回 0"
assert_file "$SCRIPT_DIR/menu.sh" "第二次取消后脚本目录仍在"
assert_file /etc/cron.d/sbshell-ui "第二次取消后面板 cron 仍在"
assert_grep 'alias sb=' /root/.bashrc "第二次取消后 bashrc 未被清理"

# ---------------------------------------------------------- 3) 两步都确认
suite_begin "debian uninstall: 正常卸载只清 Sbshell 脚本并保留配置"
setup_uninstall_case
run_uninstall 'y\ny\n'; rc=$?
out=$(cat /tmp/u18.out)
assert_rc "$rc" 0 "正常卸载返回 0"
assert_not_rc "$rc" 124 "正常卸载没有挂住（未被超时杀掉）"
assert_contains "$out" "Sbshell 已卸载" "给出卸载完成提示"
assert_no_file "$SCRIPT_DIR/menu.sh" "脚本目录已删除"
if [ ! -d "$SCRIPT_DIR" ]; then pass "脚本目录本身已删除"; else fail "脚本目录本身已删除 (still present)"; fi
assert_no_file /usr/local/bin/sb "快捷方式已删除"
assert_no_file /etc/cron.d/sbshell-ui "面板 cron 已删除"
assert_no_file /etc/cron.d/sbshell-singbox "自动更新 cron 已删除"
assert_no_file "$INITIALIZED_FILE" "初始化标记已删除"
assert_no_file "$ROLE_FILE" "角色文件已删除"
assert_file /etc/sing-box/config.json "配置保留（Debian 卸载不删 /etc/sing-box）"
assert_no_grep 'alias sb=' /root/.bashrc "bashrc 快捷方式块已清理"
assert_grep 'keep-me' /root/.bashrc "bashrc 其它内容保留"

# ------------------------------------------------------------- 4) EOF 不死循环
suite_begin "debian uninstall: stdin EOF 时必须取消而不是死循环"
setup_uninstall_case
run_uninstall ''; rc=$?
out=$(cat /tmp/u18.out)
assert_not_rc "$rc" 124 "EOF 不会死循环（未被超时杀掉）"
assert_contains "$out" "无法读取输入（EOF）" "EOF 时明确提示无法读取输入"
assert_rc "$rc" 0 "EOF 取消返回 0"
assert_file "$SCRIPT_DIR/menu.sh" "EOF 取消后脚本目录仍在"

suite_end
