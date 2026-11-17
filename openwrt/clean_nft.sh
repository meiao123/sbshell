#!/bin/bash
set -Eeuo pipefail

# 公共实现（install 兜底、防火墙参数）集中在 lib.sh，避免三份副本漂移。
_sbshell_lib_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$_sbshell_lib_dir/lib.sh" || { echo '缺少 lib.sh，请先在菜单 9 更新脚本。' >&2; exit 1; }

# 两阶段提交：pending 文件也代表「本次/上次是 Sbshell 在建表」，崩溃后仍可回收。
fw_owned() { # $1=state 文件
    { [ -f "$1" ] && grep -q '^OWNER=sbshell$' "$1"; } ||
    { [ -f "$1.pending" ] && grep -q '^OWNER=sbshell$' "$1.pending"; } ||
    { [ -f "$1" ] && grep -q '^PENDING=1$' "$1"; }
}

[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
TPROXY_STATE_FILE=/etc/sing-box/tproxy.state
TUN_STATE_FILE=/etc/sing-box/tun.state
TABLE_LIST=$(mktemp /tmp/sbshell-nft-tables.XXXXXX) || exit 1
trap 'rm -f "$TABLE_LIST"' EXIT

wait_for_singbox_exit() {
    local elapsed=0
    while pidof sing-box >/dev/null 2>&1; do
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge 10 ]; then
            echo 'sing-box 仍在运行，防火墙清理已中止。' >&2
            return 1
        fi
        sleep 1
    done
}

# 精确匹配 fwmark/table，避免 "fwmark 0x1" 命中 "fwmark 0x10"。
rule_pref_for_mark() {
    ip -4 rule show | awk -v m="0x$1" -v t="$2" '
        {
            pref = $0; sub(/:.*/, "", pref)
            fw = ""; lu = ""
            for (i = 1; i < NF; i++) {
                if ($i == "fwmark") fw = $(i + 1)
                else if ($i == "lookup" || $i == "table") lu = $(i + 1)
            }
            if ((fw == m || fw == m "/0xffffffff") && lu == t) { print pref; exit }
        }'
}
route_default_exists() {
    ip -4 route show table "$SBSHELL_ROUTE_TABLE" | awk -v ifc="$1" '$0 == "local default dev " ifc || index($0, "local default dev " ifc " ") == 1 {found=1} END {exit !found}'
}

# 表存在性判定：`nft list table` 失败无法区分“不存在”与“nft 报错”，
# 当成“不存在”会跳过所有权校验又删掉 state，留下再也清不掉的表。
table_state() {
    nft list tables > "$TABLE_LIST" 2>/dev/null || { echo unknown; return 0; }
    if grep -qx "table inet $1" "$TABLE_LIST"; then echo present; else echo absent; fi
}

clean_owned_table() {
    local table="$1" state_file="$2" label="$3" keep_state="${4:-0}" state
    state=$(table_state "$table")
    case "$state" in
        unknown)
            echo "无法确定 inet $table 表状态（nft 不可用或报错），保留 $state_file。" >&2
            return 1
            ;;
        present)
            if fw_owned "$state_file"; then
                if ! nft delete table inet "$table"; then
                    echo "删除 inet $table 失败，保留 $state_file 以便重试。" >&2
                    return 1
                fi
            else
                echo "检测到非 Sbshell 管理的 inet $table 表，拒绝删除。" >&2
                return 1
            fi
            ;;
    esac
    if [ -f "$state_file" ] && ! grep -q '^OWNER=sbshell$' "$state_file"; then
        echo "检测到非 Sbshell 的 $state_file，拒绝删除。" >&2
        return 1
    fi
    # C1：先删表、后删策略路由时由调用方保留 state，等路由清完再删（否则路由永远清不掉）。
    if [ "$keep_state" -eq 1 ]; then
        return 0
    fi
    # 两阶段提交的 pending 一并清掉，不留"只有 pending"的残骸。
    rm -f "$state_file" "$state_file.pending"
    echo "$label 防火墙状态已清理。"
}

clean_tproxy_routes() {
    if fw_owned "$TPROXY_STATE_FILE"; then
        local pref interface rule_owned route_owned state_src
        # 只有 pending、没有 state（上次在建表与落盘之间崩溃）时，字段从 pending 里读。
        state_src="$TPROXY_STATE_FILE"
        [ -f "$state_src" ] || state_src="$TPROXY_STATE_FILE.pending"
        pref=$(sed -n 's/^RULE_PREF=//p' "$state_src" | head -n1)
        interface=$(sed -n 's/^INTERFACE=//p' "$state_src" | head -n1)
        rule_owned=0; route_owned=0
        grep -q '^RULE_OWNED=1$' "$state_src" && rule_owned=1
        grep -q '^ROUTE_OWNED=1$' "$state_src" && route_owned=1
        [ "$rule_owned" -eq 1 ] || { grep -q '^RULE_CREATED=1$' "$state_src" && rule_owned=1; }
        [ "$route_owned" -eq 1 ] || { grep -q '^ROUTE_CREATED=1$' "$state_src" && route_owned=1; }
        if [ "$rule_owned" -eq 1 ] && [ -n "$pref" ]; then
            ip -4 rule del pref "$pref" fwmark "$SBSHELL_PROXY_FWMARK" lookup "$SBSHELL_ROUTE_TABLE" 2>/dev/null || true
        fi
        if [ "$route_owned" -eq 1 ] && [ -n "$interface" ]; then
            ip -4 route del local default dev "$interface" table "$SBSHELL_ROUTE_TABLE" 2>/dev/null || true
        fi
        # 复核是否真的清掉了；没清掉就保留 state（避免 state 已删、规则还在）。
        if [ "$rule_owned" -eq 1 ] && [ -n "$(rule_pref_for_mark "$SBSHELL_PROXY_FWMARK" "$SBSHELL_ROUTE_TABLE")" ]; then
            echo "策略规则仍存在，保留 $TPROXY_STATE_FILE 以便重试。" >&2
            return 1
        fi
        if [ "$route_owned" -eq 1 ] && [ -n "$interface" ] && route_default_exists "$interface"; then
            echo "table $SBSHELL_ROUTE_TABLE 的本地默认路由仍存在，保留 $TPROXY_STATE_FILE 以便重试。" >&2
            return 1
        fi
    fi
    return 0
}

wait_for_singbox_exit
# C2：第一次 nft delete 之前加锁，避免与并发的 configure/clean 互相拆表；无 flock 时静默跳过。
LOCK_FILE=/var/lock/sbshell-firewall.lock
mkdir -p /var/lock
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -w 20 9 || { echo '另一个防火墙操作正在进行，请稍后重试。' >&2; exit 1; }
fi
# A-21：nftables.conf 是普通文件、没有所有权凭据，所以先在清理**之前**判定它是否
# 属于 Sbshell 的 TUN 部署（表存在，或 state 写着 OWNER=sbshell），只有属于才删。
# 旧写法无条件 rm -f，会静默删掉第三方放进这个目录的文件。用 if 形式判定：
# `[ -f … ] && grep -q … && x=1` 在 set -e 下失败会直接终止脚本。
tun_owned=0
if fw_owned "$TUN_STATE_FILE"; then
    tun_owned=1
fi
nft_tun_present=0
if nft list table inet sing-box-tun >/dev/null 2>&1; then
    nft_tun_present=1
fi
clean_owned_table sing-box-tun "$TUN_STATE_FILE" TUN || exit 1
# C1：先删 sing-box 表、再删策略路由：反过来时若删表失败，会留下"表在、路由没了"的半死状态。
clean_owned_table sing-box "$TPROXY_STATE_FILE" TProxy 1 || exit 1
clean_tproxy_routes || exit 1
# state 与两阶段提交的 pending 一起删：清理完成后不允许再留下"我们拥有这张表"的凭据。
rm -f "$TPROXY_STATE_FILE" "$TPROXY_STATE_FILE.pending"
echo 'TProxy 防火墙状态已清理。'
if [ "$nft_tun_present" -eq 1 ] || [ "$tun_owned" -eq 1 ]; then
    rm -f /etc/sing-box/tun/nftables.conf
fi
rmdir /etc/sing-box/tun 2>/dev/null || true

echo 'sing-box 服务已停止, Sbshell 管理的 TProxy/TUN 防火墙规则已清理。'
