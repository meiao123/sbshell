#!/usr/bin/env bash
# 测试公共库：断言、状态重置、仓库脚本安装。
# 由各套件 `. "$(dirname "$0")/../lib/harness.sh"` 引入。

SBSHELL_SRC="${SBSHELL_SRC:-/src}"
SBSHELL_STUB_STATE="${SBSHELL_STUB_STATE:-/tmp/sbshell-stub-state}"
SBSHELL_FIXTURES="${SBSHELL_FIXTURES:-/tmp/sbshell-fixtures}"
CHECK_COUNT=0
FAIL_COUNT=0

suite_begin() { printf '== %s ==\n' "$*"; }
suite_end() {
    printf -- '-- %d checks, %d failures\n' "$CHECK_COUNT" "$FAIL_COUNT"
    [ "$FAIL_COUNT" -eq 0 ] || exit 1
}

pass() { CHECK_COUNT=$((CHECK_COUNT + 1)); printf '  ok    %s\n' "$*"; }
fail() { CHECK_COUNT=$((CHECK_COUNT + 1)); FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  FAIL  %s\n' "$*"; }

assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got '$1' want '$2')"; fi; }
assert_rc() { if [ "$1" = "$2" ]; then pass "$3 (rc=$1)"; else fail "$3 (rc=$1, want $2)"; fi; }
assert_not_rc() { if [ "$1" != "$2" ]; then pass "$3 (rc=$1)"; else fail "$3 (rc=$1, want != $2)"; fi; }
assert_file() { if [ -f "$1" ]; then pass "$2"; else fail "$2 (missing file $1)"; fi; }
assert_no_file() { if [ -e "$1" ]; then fail "$2 (unexpected $1)"; else pass "$2"; fi; }
assert_dir() { if [ -d "$1" ]; then pass "$2"; else fail "$2 (missing dir $1)"; fi; }
assert_grep() { if grep -q -- "$1" "$2" 2>/dev/null; then pass "$3"; else fail "$3 (pattern '$1' not found in $2)"; fi; }
assert_no_grep() { if grep -q -- "$1" "$2" 2>/dev/null; then fail "$3 (pattern '$1' found in $2)"; else pass "$3"; fi; }
assert_contains() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 ('$2' not in output)" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3 ('$2' present in output)" ;; *) pass "$3" ;; esac; }

run_with_timeout() { timeout "${SBSHELL_TIMEOUT:-90}" "$@"; }

# ---------- 状态重置 ----------
reset_stub_state() {
    rm -rf "$SBSHELL_STUB_STATE"
    mkdir -p "$SBSHELL_STUB_STATE/nft"
    : > "$SBSHELL_STUB_STATE/ip_rules"
    : > "$SBSHELL_STUB_STATE/curl.log"
    : > "$SBSHELL_STUB_STATE/nft.log"
    : > "$SBSHELL_STUB_STATE/ip.log"
    : > "$SBSHELL_STUB_STATE/systemctl.log"
    : > "$SBSHELL_STUB_STATE/initd.log"
    unset SBSHELL_NFT_FAIL SBSHELL_SINGBOX_FAIL SBSHELL_NO_IPV6 SBSHELL_IPV4_FORWARD SBSHELL_IPV6_FORWARD
}

# 脚本（以及新加的 getent group sing-box 逻辑）要求存在 sing-box 服务组；
# 测试环境必须显式创建，否则 suite 04 单独运行会失败（也会掩盖真实的组依赖问题）。
ensure_singbox_user() {
    getent group sing-box >/dev/null 2>&1 || groupadd --system sing-box 2>/dev/null || true
    id sing-box >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin \
        -g sing-box sing-box 2>/dev/null || true
}
reset_singbox_dir() { rm -rf /etc/sing-box; mkdir -p /etc/sing-box/scripts; ensure_singbox_user; }
reset_openwrt_dirs() {
    rm -rf /etc/rc.d /etc/crontabs
    mkdir -p /etc/rc.d /etc/crontabs
    install -m 0755 "${SBSHELL_TEST_ROOT:-/opt/tests}/initd/sing-box" /etc/init.d/sing-box
    install -m 0755 "${SBSHELL_TEST_ROOT:-/opt/tests}/initd/cron" /etc/init.d/cron
    rm -f /etc/init.d/sbshell-firewall
}

# 把仓库里的脚本装到脚本目录（模拟安装完成后的状态）
install_repo_scripts() {
    local flavour="$1"
    mkdir -p /etc/sing-box/scripts
    cp -a "$SBSHELL_SRC/$flavour"/*.sh /etc/sing-box/scripts/
    chmod 0755 /etc/sing-box/scripts/*.sh
}

# curl stub 用的 fixture 目录：URL 的 basename 即文件名
reset_fixtures() {
    rm -rf "$SBSHELL_FIXTURES"
    mkdir -p "$SBSHELL_FIXTURES"
    export SBSHELL_FIXTURES
}
fixture_from_repo() { cp "$SBSHELL_SRC/$1" "$SBSHELL_FIXTURES/$(basename "$1")"; }
fixture_write() { printf '%s\n' "$2" > "$SBSHELL_FIXTURES/$1"; }
fixture_copy() { cp "$1" "$SBSHELL_FIXTURES/$2"; }

VALID_CLIENT_CONFIG='{"log":{"level":"info"},"inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":7893}],"outbounds":[{"type":"direct","tag":"direct"}]}'

# ---------- nft / ip 状态查询 ----------
nft_table_exists() { [ -f "$SBSHELL_STUB_STATE/nft/inet__$1" ]; }
nft_table_dump() { cat "$SBSHELL_STUB_STATE/nft/inet__$1" 2>/dev/null; }
ip_rules() { cat "$SBSHELL_STUB_STATE/ip_rules" 2>/dev/null; }
ip_route_table() { cat "$SBSHELL_STUB_STATE/ip_routes_$1" 2>/dev/null; }
stub_log() { cat "$SBSHELL_STUB_STATE/$1.log" 2>/dev/null; }

# 构造一个"包含当前 PATH 里全部可执行文件、唯独没有 install"的目录，用来模拟 busybox
# （OpenWrt/ImmortalWrt 没有 install applet；而测试镜像装了 coreutils，真 install 始终存在，
# 所以断言 install() 兜底的行为必须在受限 PATH 下做，否则测到的是 GNU install）。
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
