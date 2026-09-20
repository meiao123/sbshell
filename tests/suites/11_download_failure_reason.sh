#!/bin/bash
# 真机回归（ImmortalWrt 25.12.2 + apk，2026-09-15）：
#   配置文件下载中，超时倒计时: 23s
#   curl: (22) The requested URL returned error: 500
#   配置文件下载超时（30s），未修改现有配置。
# 后端返回 HTTP 500（服务端错误）被误报成"下载超时"。根因：openwrt/manual_input.sh 在
# set -Eeuo pipefail 下用后台子 shell 跑 curl，errexit 在 curl 失败时直接干掉子 shell，
# 写状态文件的那句永远执行不到，父进程空转 30 秒后走"超时"分支，真实原因被掩盖。
# 本套件要求：失败必须立刻给出真实原因，并且现有配置不被改动。
. "$(dirname "$0")/../lib/harness.sh"

MANUAL=/etc/sing-box/scripts/manual_input.sh
OUT=/tmp/manual-download-fail.out
MARKER=/tmp/manual-config-before.json

prepare_env() {
    reset_stub_state
    reset_singbox_dir
    reset_openwrt_dirs
    reset_fixtures
    install_repo_scripts openwrt
    printf 'MODE=TUN\n' > /etc/sing-box/mode.conf
    cat > /etc/sing-box/defaults.conf <<'EOF'
BACKEND_URL=https://backend.test
SUBSCRIPTION_URL=tk?token=demo
TPROXY_TEMPLATE_URL=https://tpl.test/template.json
TUN_TEMPLATE_URL=https://tpl.test/template.json
EOF
    fixture_write template.json "$VALID_CLIENT_CONFIG"
    printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json
    cp /etc/sing-box/config.json "$MARKER"
}

run_manual_failing() { # $1=注入的 curl 退出码  $2=注入的 HTTP 状态码
    export SBSHELL_CURL_FAIL="$1"
    export SBSHELL_CURL_HTTP="$2"
    _start=$(date +%s)
    printf '\n\n\ny\n' | run_with_timeout bash "$MANUAL" >"$OUT" 2>&1
    MANUAL_RC=$?
    MANUAL_ELAPSED=$(( $(date +%s) - _start ))
    unset SBSHELL_CURL_FAIL SBSHELL_CURL_HTTP
}

suite_begin "openwrt: 后端 HTTP 500 必须报真实原因，而不是'下载超时'"
prepare_env
run_manual_failing 22 500
assert_rc "$MANUAL_RC" 1 "HTTP 500 时 manual_input.sh 以 1 退出"
assert_grep '配置文件下载失败' "$OUT" "报告的是下载失败"
assert_no_grep '配置文件下载超时' "$OUT" "不再误报为下载超时"
assert_grep 'HTTP 500' "$OUT" "失败原因里指出服务端返回 500"
assert_grep '请求地址: http' "$OUT" "失败时打印请求地址，便于直接复制排查"
# A-11：FULL_URL 里含用户 token，失败输出只保留 scheme+host（这里刻意只检查"请求地址"那一行：
# 交互确认阶段回显用户刚输入的订阅地址是必要的，不算泄露）。
addr_line=$(grep '请求地址:' "$OUT" | head -n1)
assert_not_contains "$addr_line" 'tk?token=demo' "请求地址那行不含订阅 token 原文"
assert_contains "$addr_line" 'https://backend.test/***' "请求地址已脱敏为 scheme+host/***"
if [ "$MANUAL_ELAPSED" -lt 15 ]; then
    pass "立即失败（${MANUAL_ELAPSED}s），不再空等 30 秒"
else
    fail "失败耗时 ${MANUAL_ELAPSED}s，疑似仍在空等倒计时"
fi
if cmp -s "$MARKER" /etc/sing-box/config.json; then
    pass "失败后现有配置未被改动"
else
    fail "失败后现有配置被改动"
fi
assert_no_grep '"error":"injected failure' /etc/sing-box/config.json "失败响应体没有被当成配置提交"

suite_begin "openwrt: 鉴权/DNS/连接被拒绝/超时各自给出真实原因"
prepare_env
run_manual_failing 22 401
assert_grep 'HTTP 401' "$OUT" "401 被当作鉴权失败上报"
assert_grep '鉴权' "$OUT" "401 的提示点明鉴权问题"
assert_no_grep '配置文件下载超时' "$OUT" "401 不再报超时"

prepare_env
run_manual_failing 6 000
assert_grep '域名解析失败' "$OUT" "curl 退出码 6 报 DNS 解析失败"
assert_no_grep '配置文件下载超时' "$OUT" "DNS 失败不再报超时"

prepare_env
run_manual_failing 7 000
assert_grep '连接被拒绝' "$OUT" "curl 退出码 7 报连接被拒绝"

prepare_env
run_manual_failing 28 000
assert_grep '请求超时' "$OUT" "curl 退出码 28 报请求超时"
assert_no_grep '配置文件下载超时（30s）' "$OUT" "curl 自身的超时不再走倒计时误报分支"

suite_begin "openwrt: 成功路径不回归（fixture 正常下载、校验并提交）"
prepare_env
printf '\n\n\ny\n' | run_with_timeout bash "$MANUAL" >"$OUT" 2>&1
assert_rc "$?" 0 "正常下载时 manual_input.sh 成功"
assert_grep '配置文件下载并验证成功' "$OUT" "成功提示保持不变"
assert_grep '"level":"info"' /etc/sing-box/config.json "配置已提交到 /etc/sing-box/config.json"

suite_begin "openwrt: 失败上报的实现约束"
assert_grep 'download_failure_reason' "$MANUAL" "定义了失败原因翻译函数"
assert_grep '|| rc=' "$MANUAL" "curl 退出码被显式兜住（set -e 下不会提前结束子 shell）"
if grep -qF "printf '%s\\n' \"\$?\"" "$MANUAL"; then
    fail "仍在用裸 \$? 写法：errexit 会在 curl 失败时跳过状态写入"
else
    pass "状态文件写入不再依赖 errexit 允许跑到的裸 \$? 语句"
fi
suite_end
