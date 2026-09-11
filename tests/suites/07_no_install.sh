#!/usr/bin/env bash
# 07_no_install.sh
# 真机回归（ImmortalWrt）：busybox 常常没有 install applet，一键引导会直接中止：
#   /dev/fd/64: line 57: install: command not found
# 之前 CI 抓不到，因为测试镜像装了 coreutils（始终有 GNU install）。
# 这里构造一个"PATH 里没有 install"的环境，验证引导与所有 OpenWrt 脚本仍然可用。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SCRIPTS=/etc/sing-box/scripts

# 构造一个包含当前 PATH 里全部可执行文件、唯独没有 install 的目录。
# fakebin 桩在 PATH 最前面，因此会优先被链接（例如 curl 桩）。
path_without_install() {
    local out p f b
    out=$(mktemp -d)
    for p in $(printf '%s' "$PATH" | tr ':' '\n'); do
        [ -d "$p" ] || continue
        for f in "$p"/*; do
            [ -f "$f" ] || continue
            b=${f##*/}
            b=${b%.exe}                 # MSYS/Cygwin 上真名可能是 install.exe
            [ "$b" = install ] && continue
            [ -e "$out/$b" ] || ln -s "$f" "$out/$b" 2>/dev/null || true
        done
    done
    printf '%s' "$out"
}

suite_begin "busybox: works without an install applet (ImmortalWrt 真机回归)"

reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
for f in "$SBSHELL_SRC"/openwrt/*.sh; do cp "$f" "$SBSHELL_FIXTURES/"; done

NOPATH=$(path_without_install)
if PATH="$NOPATH" command -v install >/dev/null 2>&1; then
    fail "测试环境构造失败：受限 PATH 里 install 仍然可见"
else
    pass "受限 PATH 里 install 不可见（模拟 busybox）"
fi
if PATH="$NOPATH" command -v curl >/dev/null 2>&1; then
    pass "受限 PATH 仍能找到 curl 桩（断言才有意义）"
else
    fail "受限 PATH 丢了 curl 桩"
fi

# 1) 静态：所有依赖 install 的 OpenWrt 脚本都必须自带兜底。
#    只认"install 后跟选项"的命令用法，避免把 `opkg install curl` 误判成依赖。
for f in sbshall.sh openwrt/*.sh; do
    grep -qE '(^|[^-[:alnum:]_])install[[:space:]]+-' "$SBSHELL_SRC/$f" || continue
    if grep -q 'command -v install' "$SBSHELL_SRC/$f"; then
        pass "$f 自带 install 兜底"
    else
        fail "$f 依赖 install 却没有兜底（busybox 上会 command not found）"
    fi
done

# auto_update.sh 用 heredoc 生成给 cron 的那份也必须带兜底（否则 cron 静默不更新配置）。
awk '/^cat > .*UPDATE_SCRIPT/{p=1} p{print} p&&/^EOF$/{exit}' \
    "$SBSHELL_SRC/openwrt/auto_update.sh" > /tmp/gen-update-script.sh
if grep -q 'command -v install' /tmp/gen-update-script.sh; then
    pass "auto_update.sh 生成给 cron 的脚本自带兜底"
else
    fail "生成的 cron 脚本依赖 install 却没有兜底"
fi

# 2) 行为：set_defaults.sh 需要 install -d（目录+权限）与 install -m（文件+权限）。
printf 'https://backend.test\nsub?token=demo\nhttps://tpl.test/tproxy.json\nhttps://tpl.test/tun.json\n' \
    | PATH="$NOPATH" run_with_timeout bash "$SCRIPTS/set_defaults.sh" > /tmp/no-install-sd.out 2>&1
assert_rc "$?" 0 "无 install 环境下 set_defaults.sh 成功"
assert_file /etc/sing-box/defaults.conf "写入 defaults.conf"
assert_eq "$(stat -c %a /etc/sing-box/defaults.conf)" "600" "defaults.conf 权限 0600"
assert_eq "$(stat -c %a /etc/sing-box)" "755" "/etc/sing-box 目录权限 0755"

# 3) 行为：生成的 cron 更新脚本（heredoc 那一份）也必须在无 install 环境下工作。
cat > /etc/sing-box/manual.conf <<'EOS'
BACKEND_URL=https://backend.test
SUBSCRIPTION_URL=tk?token=demo
TEMPLATE_URL=https://tpl.test/template.json
EOS
fixture_write template.json "$VALID_CLIENT_CONFIG"
printf '1\n12\n' | run_with_timeout bash "$SCRIPTS/auto_update.sh" > /tmp/no-install-au.out 2>&1 || true
assert_file /etc/sing-box/update-singbox.sh "生成 cron 更新脚本"
rm -f /etc/sing-box/config.json
PATH="$NOPATH" run_with_timeout bash /etc/sing-box/update-singbox.sh > /tmp/no-install-cron.out 2>&1
cron_rc=$?
if [ "$cron_rc" -ne 0 ]; then
    fail "无 install 环境下 cron 更新脚本失败（rc=$cron_rc）"
    tail -20 /tmp/no-install-cron.out
else
    pass "无 install 环境下 cron 更新脚本成功"
fi
assert_file /etc/sing-box/config.json "cron 脚本写入配置"
if [ -f /etc/sing-box/config.json ]; then
    assert_eq "$(stat -c %a /etc/sing-box/config.json)" "600" "配置权限 0600"
fi

suite_end
