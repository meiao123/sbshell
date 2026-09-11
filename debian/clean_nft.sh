#!/bin/bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100
TPROXY_STATE_FILE=/etc/sing-box/tproxy.state
TUN_STATE_FILE=/etc/sing-box/tun.state
TABLE_LIST=$(mktemp /tmp/sbshell-nft-tables.XXXXXX) || exit 1
trap 'rm -f "$TABLE_LIST"' EXIT

systemctl stop sing-box >/dev/null 2>&1 || true

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
    ip -4 route show table "$PROXY_ROUTE_TABLE" | awk -v ifc="$1" '$0 == "local default dev " ifc || index($0, "local default dev " ifc " ") == 1 {found=1} END {exit !found}'
}

# 表存在性判定：`nft list table` 失败时无法区分“表不存在”与“nft 报错”，
# 直接当成“表不存在”会跳过所有权校验并删掉 state 文件，留下再也清不掉的表。
# 因此改用 `nft list tables` 全量列举：列举成功才判断存在性，失败则视为“不确定”。
table_state() {
    nft list tables > "$TABLE_LIST" 2>/dev/null || { echo unknown; return 0; }
    if grep -qx "table inet $1" "$TABLE_LIST"; then echo present; else echo absent; fi
}

clean_owned_table() {
    local table="$1" state_file="$2" label="$3" state
    state=$(table_state "$table")
    case "$state" in
        unknown)
            echo "无法确定 inet $table 表状态（nft 不可用或报错），保留 $state_file。" >&2
            return 1
            ;;
        present)
            if [ -f "$state_file" ] && grep -q '^OWNER=sbshell$' "$state_file"; then
                # 删除失败必须中止：旧代码把本函数放在 `|| exit 1` 左侧，函数体内 errexit 失效，
                # 于是删除失败也会继续删掉 state 并报告“已清理”，
                # 留下一张没有所有权凭证、之后再也清不掉的表。
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
    # 只有确认表是我们自己的（或表确实不存在）时才删除 state 文件。
    if [ -f "$state_file" ] && ! grep -q '^OWNER=sbshell$' "$state_file"; then
        echo "检测到非 Sbshell 的 $state_file，拒绝删除。" >&2
        return 1
    fi
    rm -f "$state_file"
    echo "$label 防火墙状态已清理。"
}

clean_tproxy_routes() {
    if [ -f "$TPROXY_STATE_FILE" ] && grep -q '^OWNER=sbshell$' "$TPROXY_STATE_FILE"; then
        local pref interface rule_owned route_owned
        pref=$(sed -n 's/^RULE_PREF=//p' "$TPROXY_STATE_FILE" | head -n1)
        interface=$(sed -n 's/^INTERFACE=//p' "$TPROXY_STATE_FILE" | head -n1)
        rule_owned=0; route_owned=0
        grep -q '^RULE_OWNED=1$' "$TPROXY_STATE_FILE" && rule_owned=1
        grep -q '^ROUTE_OWNED=1$' "$TPROXY_STATE_FILE" && route_owned=1
        [ "$rule_owned" -eq 1 ] || { grep -q '^RULE_CREATED=1$' "$TPROXY_STATE_FILE" && rule_owned=1; }
        [ "$route_owned" -eq 1 ] || { grep -q '^ROUTE_CREATED=1$' "$TPROXY_STATE_FILE" && route_owned=1; }
        if [ "$rule_owned" -eq 1 ] && [ -n "$pref" ]; then
            ip -4 rule del pref "$pref" fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE" 2>/dev/null || true
        fi
        if [ "$route_owned" -eq 1 ] && [ -n "$interface" ]; then
            ip -4 route del local default dev "$interface" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true
        fi
        # 复核是否真的清掉了；没清掉就保留 state，避免“state 已删、规则还在”。
        if [ "$rule_owned" -eq 1 ] && [ -n "$(rule_pref_for_mark "$PROXY_FWMARK" "$PROXY_ROUTE_TABLE")" ]; then
            echo "策略规则仍存在，保留 $TPROXY_STATE_FILE 以便重试。" >&2
            return 1
        fi
        if [ "$route_owned" -eq 1 ] && [ -n "$interface" ] && route_default_exists "$interface"; then
            echo "table $PROXY_ROUTE_TABLE 的本地默认路由仍存在，保留 $TPROXY_STATE_FILE 以便重试。" >&2
            return 1
        fi
    fi
    return 0
}

clean_owned_table sing-box-tun "$TUN_STATE_FILE" TUN || exit 1
clean_tproxy_routes || exit 1
clean_owned_table sing-box "$TPROXY_STATE_FILE" TProxy || exit 1
rm -f /etc/sing-box/tun/nftables.conf
rmdir /etc/sing-box/tun 2>/dev/null || true

echo "sing-box 服务已停止，Sbshell 管理的 TProxy/TUN 防火墙状态已清理。"
