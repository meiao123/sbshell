#!/usr/bin/env bash
# 25_batch8_p3_polish.sh —— 批次 8：openwrt 域 P3 集群。
#
#   A-20 死代码与文案/行为不一致（卸载清单里的 cron.d 死路径、二级菜单重复打印）
#   A-21 clean_nft.sh 无条件删 /etc/sing-box/tun/nftables.conf
#   A-24 check_environment.sh 用字段位置解析版本、且不探测 nft/tun
#   A-25 install_ui 回滚分支里 `A || B` 的 B 被 errexit 带走，告警与清理都执行不到
#   A-27 menu.sh 只透传 UI 安装器输出的最后一行，用户看不到「UI 安装完成。」
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SRC="${SBSHELL_SRC:-/src}"

# ------------------------------------------- A-20 死代码与文案/行为一致
suite_begin "批次8 A-20：卸载清单与二级菜单"

# A-20(1)：这两个路径现行版本已不再创建（UI 计划任务写在 /etc/crontabs/root），
# 但卸载仍继续清理它们以兼容早期版本 —— 断言注释说明了这一点，避免被误读成现行布局。
assert_grep '兼容旧安装' "$SRC/openwrt/menu.sh" "menu.sh 注明 cron.d 路径是历史遗留清理"
assert_grep 'rm -f.*/etc/cron\.d/sbshell' "$SRC/openwrt/menu.sh" "继续清理早期版本留下的 cron.d 文件"
assert_eq "$(grep -cE '^[[:space:]]*show_submenu$' "$SRC/openwrt/commands.sh")" "1" \
    "二级菜单只由外层 while 打印（选 0 退出时不再多印一遍）"
# A-20(2)/(3) 经核对已自洽：批次 1 把 valid_url 收窄为仅 https 后文案一致，
# 批次 4 删掉了恒真的 `!= ''`。这里做固化，防止回退。
assert_grep 'valid_url() { \[\[ "\$1" =~ \^https://' "$SRC/openwrt/manual_update.sh" \
    "manual_update.sh 的 URL 校验只接受 https"
assert_eq "$(grep -c "!= ''" "$SRC/openwrt/manual_update.sh")" "0" \
    "manual_update.sh 不再有恒真死条件"

# ------------------------------------------- A-21 只删自己管理的文件
suite_begin "批次8 A-21：clean_nft.sh 不再无条件删 tun/nftables.conf"

clean_nft="$SRC/openwrt/clean_nft.sh"
assert_grep 'nft_tun_present' "$clean_nft" "清理前记录 TUN 表是否存在"
assert_grep 'if \[ "\$nft_tun_present" -eq 1 \] || \[ "\$tun_owned" -eq 1 \]; then' "$clean_nft" \
    "仅当表存在或 state 声明 OWNER=sbshell 时才删文件"

# 场景 A：没有任何所有权凭据（无 TUN 表、无 state）→ 第三方放的文件必须保留
reset_stub_state 2>/dev/null || true
reset_openwrt_dirs 2>/dev/null || true
mkdir -p /etc/sing-box/tun
printf 'table inet third-party {\n    chain c {\n        counter\n    }\n}\n' > /etc/sing-box/tun/nftables.conf
rm -f /etc/sing-box/tun.state /etc/sing-box/tproxy.state
run_with_timeout bash "$clean_nft" > /tmp/g25-a.out 2>&1 || true
assert_file /etc/sing-box/tun/nftables.conf "无所有权凭据时保留第三方 tun/nftables.conf"

# 场景 B：state 声明 OWNER=sbshell 且 TUN 表存在 → 必须连文件一起清理
reset_stub_state 2>/dev/null || true
reset_openwrt_dirs 2>/dev/null || true
mkdir -p /etc/sing-box/tun
printf 'table inet third-party {\n    chain c {\n        counter\n    }\n}\n' > /etc/sing-box/tun/nftables.conf
printf 'OWNER=sbshell\nTABLE=sing-box-tun\n' > /etc/sing-box/tun.state
printf 'table inet sing-box-tun {\n    chain c {\n        counter\n    }\n}\n' > /tmp/g25-tun.nft
nft -f /tmp/g25-tun.nft >/dev/null 2>&1
run_with_timeout bash "$clean_nft" > /tmp/g25-b.out 2>&1 || true
assert_no_file /etc/sing-box/tun/nftables.conf "OWNER=sbshell 时清理 tun/nftables.conf"

# ------------------------------------------- A-24 版本解析与环境探测
suite_begin "批次8 A-24：check_environment.sh 版本解析与环境探测"

out=$(run_with_timeout bash "$SRC/openwrt/check_environment.sh" 2>&1)
assert_contains "$out" "1.12.0" "从桩的 'sing-box version 1.12.0' 解析出版本号"
assert_contains "$out" "nft 可用" "报告 nft 可用性"
assert_contains "$out" "/dev/net/tun" "报告 TUN 设备可用性"

# 带附加信息的版本行：仍要取到版本号（不能依赖字段位置）
weird=$(mktemp -d)
printf '#!/bin/bash\n[ "${1:-}" = version ] && { echo "sing-box version v1.13.0-beta.1 (go1.24)"; exit 0; }\nexit 0\n' > "$weird/sing-box"
chmod +x "$weird/sing-box"
out2=$(run_with_timeout env PATH="$weird:$PATH" bash "$SRC/openwrt/check_environment.sh" 2>&1)
assert_contains "$out2" "v1.13.0-beta.1" "带附加信息的版本行也能解析出正确版本号"

# 完全无法解析的版本行：必须明确提示，而不是打印空版本号
printf '#!/bin/bash\n[ "${1:-}" = version ] && { echo "sing-box (devel)"; exit 0; }\nexit 0\n' > "$weird/sing-box"
out3=$(run_with_timeout env PATH="$weird:$PATH" bash "$SRC/openwrt/check_environment.sh" 2>&1)
assert_contains "$out3" "无法从版本输出解析出版本号" "解析失败时给出明确提示"
assert_not_contains "$out3" "版本：$" "不会打印空的版本号"
rm -rf "$weird"

# ------------------------------------------- A-25 回滚分支不再被 errexit 带走
suite_begin "批次8 A-25：install_ui 回滚路径显式处理恢复失败"

ui="$SRC/openwrt/update_ui.sh"
assert_grep 'if \[ -n "\$backup" \] && ! mv "\$backup" "\$UI_DIR"; then' "$ui" \
    "回滚改成显式 if（恢复失败不再触发 errexit）"
assert_grep '旧 UI 恢复也失败' "$ui" "恢复失败时给出可操作告警"
assert_no_grep '\[ -z "\$backup" \] || mv "\$backup" "\$UI_DIR"' "$ui" \
    "旧的 `A || B` 回滚写法已移除"

# ------------------------------------------- A-27 透传关键行
suite_begin "批次8 A-27：菜单透传 UI 安装的关键行"

menu="$SRC/openwrt/menu.sh"
assert_grep 'UI 安装完成|UI 压缩包下载失败' "$menu" "改为过滤关键行而不是只取尾行"

# 行为断言：抽出 install_default_ui，用打印两行（完成 + 提示）的 update_ui.sh 驱动。
awk '/^install_default_ui\(\)/{p=1} p{print} p&&/^\}$/{exit}' "$menu" > /tmp/g25-idu.sh
assert_grep 'UI_INSTALL_TRIED' /tmp/g25-idu.sh "抽到了 install_default_ui 函数体"

mkdir -p /tmp/g25-stub
cat > /tmp/g25-stub/update_ui.sh <<'EOS'
#!/usr/bin/env bash
echo "UI 安装完成。"
echo "提示：配置里没有可用的 external_controller/external_ui，无法自动确认面板是否可访问。"
exit 0
EOS
cat > /tmp/g25-driver.sh <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
UI_DIR=/tmp/g25-ui-not-created
GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''
run() { bash /tmp/g25-stub/update_ui.sh; }
. /tmp/g25-idu.sh
install_default_ui
EOS
out=$(run_with_timeout bash /tmp/g25-driver.sh 2>&1)
assert_contains "$out" "UI 安装完成。" "两行输出下用户仍能看到「UI 安装完成。」"
assert_contains "$out" "external_controller" "提示行也一并透出（不再只剩一行）"

suite_end
