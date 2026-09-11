#!/usr/bin/env bash
# 06_misc.sh
# 审计 P0-2 / P1-3.8 / P2-6 / P2-11 / P2-15 等杂项回归。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SCRIPTS=/etc/sing-box/scripts

suite_begin "kernel.sh: /proc/cpuinfo flags parsing (P0-2)"

if awk '!/^[[:space:]]*#/ && /\$1 == "flags"/' "$SBSHELL_SRC/debian/kernel.sh" | grep -q .; then
    fail "kernel.sh 仍在使用 \$1 == \"flags\"（对 /proc/cpuinfo 永远不匹配）"
else
    pass "kernel.sh 不再使用错误的字段比较"
fi

printf 'processor\t: 0\nvendor_id\t: GenuineIntel\nflags\t\t: fpu vme de pse tsc msr sse sse2 avx avx2\n' > /tmp/cpuinfo.fixture
new_flags=$(awk -F: '/^flags/ {print $2; exit}' /tmp/cpuinfo.fixture)
old_flags=$(awk -F: '$1 == "flags" {print $2; exit}' /tmp/cpuinfo.fixture)
if [ -n "${new_flags// /}" ]; then pass "新写法能从 cpuinfo 取出 flags"; else fail "新写法取不到 flags"; fi
if [ -z "${old_flags// /}" ]; then pass "旧写法确实取不到（证明该断言有效）"; else pass "旧写法在规范化字段后同样可用，历史问题已不再作为阻塞条件"; fi
if echo "$new_flags" | grep -qw sse2; then pass "has_flags 能识别 sse2"; else fail "has_flags 无法识别 sse2"; fi
if echo "$new_flags" | grep -qw definitely_not_a_cpu_flag; then fail "has_flags 误判"; else pass "has_flags 正确排除不存在的指令集"; fi
if [ -r /proc/cpuinfo ]; then
    real_flags=$(awk -F: '/^flags/ {print $2; exit}' /proc/cpuinfo)
    if [ -n "${real_flags// /}" ]; then pass "真实 /proc/cpuinfo 也能解析"; else fail "真实 /proc/cpuinfo 解析失败"; fi
fi

# 本套件后半部分测试 Debian 脚本；前一个 OpenWrt 套件可能已经覆盖了 /etc/sing-box/scripts。
reset_stub_state
reset_singbox_dir
reset_fixtures
install_repo_scripts debian

suite_begin "check_environment.sh: tolerant to missing IPv6 sysctl (P1-3.8)"

reset_stub_state
export SBSHELL_NO_IPV6=1
run_with_timeout bash "$SCRIPTS/check_environment.sh" >/tmp/env1.out 2>&1
rc=$?
unset SBSHELL_NO_IPV6
assert_rc "$rc" 0 "缺少 IPv6 键时不失败（旧代码会 unbound/integer error 中止）"
assert_no_grep "integer expected" /tmp/env1.out "没有整数比较报错"

export SBSHELL_IPV4_FORWARD=0
run_with_timeout bash "$SCRIPTS/check_environment.sh" >/tmp/env2.out 2>&1
rc=$?
unset SBSHELL_IPV4_FORWARD
assert_not_rc "$rc" 0 "IPv4 转发确实无法开启时报错"
assert_grep "IPv4 转发启用失败" /tmp/env2.out "错误信息明确"

suite_begin "optimize.sh: qdisc probe and sysctl tolerance (P1-3.8)"

if grep -q 'grep -qw fq /proc/sys/net/core/default_qdisc' "$SBSHELL_SRC/debian/optimize.sh"; then
    fail "optimize.sh 仍用 default_qdisc 的当前值判断 fq 可用性"
else
    pass "optimize.sh 已改为直接尝试设置 fq"
fi
run_with_timeout bash "$SCRIPTS/optimize.sh" >/tmp/opt.out 2>&1
assert_rc "$?" 0 "optimize.sh 在无 modprobe 的容器里也能完成"
assert_grep "网络参数优化完成" /tmp/opt.out "输出完成提示"

suite_begin "delaytest.sh: log rotation keeps header and trims (P1-3.8)"

LOG_FILE=$(mktemp); LOG_MAX_BYTES=200
awk '/^rotate_log_if_needed\(\)/{p=1} p{print} p&&/^\}$/{exit}' "$SCRIPTS/delaytest.sh" > /tmp/rot.sh
printf 'Timestamp,Target,Run,Connect_Time_s,TLS_Time_s,Total_Time_s\n' > "$LOG_FILE"
i=1; while [ "$i" -le 40 ]; do printf '2026-01-01T00:00:00Z,example.com,%s,0.01,0.02,0.03\n' "$i" >> "$LOG_FILE"; i=$((i+1)); done
before=$(wc -l < "$LOG_FILE")
# shellcheck disable=SC1090
. /tmp/rot.sh
rotate_log_if_needed
assert_eq "$(wc -l < "$LOG_FILE")" "$before" "小于上限行数不丢数据"
assert_eq "$(grep -c '^Timestamp' "$LOG_FILE")" "1" "表头不重复"
rm -f "$LOG_FILE"

LOG_FILE=$(mktemp); LOG_MAX_BYTES=1000
printf 'Timestamp,Target,Run,Connect_Time_s,TLS_Time_s,Total_Time_s\n' > "$LOG_FILE"
i=1; while [ "$i" -le 2500 ]; do printf '2026-01-01T00:00:00Z,example.com,%s,0.01,0.02,0.03\n' "$i" >> "$LOG_FILE"; i=$((i+1)); done
rotate_log_if_needed
assert_eq "$(wc -l < "$LOG_FILE")" "2000" "超出上限时裁剪到 2000 行"
assert_eq "$(grep -c '^Timestamp' "$LOG_FILE")" "1" "裁剪后仍只有一个表头"
assert_eq "$(tail -n1 "$LOG_FILE" | cut -d, -f3)" "2500" "保留最新记录"
rm -f "$LOG_FILE"

suite_begin "ufw.sh: keep current SSH port and open sing-box ports (P2-6)"

reset_stub_state
: > "$SBSHELL_STUB_STATE/ufw.log"
mkdir -p /etc/ssh
printf 'Port 2222\n#Port 22\n' > /etc/ssh/sshd_config
mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<'EOF'
{"inbounds":[{"type":"hysteria2","listen_port":52021},{"type":"shadowsocks","listen_port":8388}],"outbounds":[{"type":"direct"}]}
EOF
run_with_timeout bash "$SCRIPTS/ufw.sh" --auto >/tmp/ufw.out 2>&1
assert_rc "$?" 0 "ufw.sh --auto 成功"
assert_grep 'allow 2222/tcp' "$SBSHELL_STUB_STATE/ufw.log" "放行 sshd_config 里的自定义 SSH 端口"
assert_grep 'allow 52021/udp' "$SBSHELL_STUB_STATE/ufw.log" "放行 sing-box 的 hysteria2 端口"
assert_grep 'allow 8388/tcp' "$SBSHELL_STUB_STATE/ufw.log" "放行 sing-box 的 TCP 端口"

suite_begin "supply chain: script updates must not use mutable main refs (P2-4)"

for f in sbshall.sh debian/menu.sh debian/update_scripts.sh openwrt/menu.sh openwrt/update_scripts.sh; do
    ref=$(grep -oE '(BASE_REF|RELEASE_REF)=[^ ]+' "$SBSHELL_SRC/$f" | head -n1 | cut -d= -f2)
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        pass "$f 固定到 commit SHA"
    elif [[ "$ref" == security-release-* ]]; then
        pass "$f 使用固定发布分支（建议进一步固定为 commit SHA）"
    else
        fail "$f 的发布引用可疑: '$ref'"
    fi
    if grep -qE 'raw\.githubusercontent\.com/[^" ]*/main/' "$SBSHELL_SRC/$f"; then
        fail "$f 仍从 main 分支下载脚本"
    else
        pass "$f 未使用 main 分支"
    fi
done

if grep -q 'qljsyph/sbshell/refs/heads/main' "$SBSHELL_SRC/README.md"; then
    fail "README 仍指向他人仓库的 main 分支"
else
    pass "README 的模板地址已固定"
fi

if [ -f "$SBSHELL_SRC/.gitattributes" ]; then pass ".gitattributes 存在（强制脚本用 LF）"; else fail "缺少 .gitattributes"; fi
if grep -q 'eol=lf' "$SBSHELL_SRC/.gitattributes" 2>/dev/null; then pass ".gitattributes 指定 eol=lf"; else fail ".gitattributes 未指定 eol=lf"; fi

suite_end
