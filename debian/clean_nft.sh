#!/bin/bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100
TPROXY_STATE_FILE=/etc/sing-box/tproxy.state
TUN_STATE_FILE=/etc/sing-box/tun.state

systemctl stop sing-box >/dev/null 2>&1 || true

# 只清理 Sbshell 自有状态：nft 表按所有权校验，策略路由按 state 文件校验。
clean_owned_table() {
    local table="$1" state_file="$2" label="$3"
    if nft list table inet "$table" >/dev/null 2>&1; then
        if [ -f "$state_file" ] && grep -q '^OWNER=sbshell$' "$state_file"; then
            nft delete table inet "$table"
        else
            echo "检测到非 Sbshell 管理的 inet $table 表，拒绝删除。" >&2
            return 1
        fi
    fi
    rm -f "$state_file"
    echo "$label 防火墙状态已清理。"
}

clean_tproxy_routes() {
    if [ -f "$TPROXY_STATE_FILE" ] && grep -q '^OWNER=sbshell$' "$TPROXY_STATE_FILE"; then
        local pref interface
        pref=$(sed -n 's/^RULE_PREF=//p' "$TPROXY_STATE_FILE" | head -n1)
        interface=$(sed -n 's/^INTERFACE=//p' "$TPROXY_STATE_FILE" | head -n1)
        if grep -q '^RULE_CREATED=1$' "$TPROXY_STATE_FILE" && [ -n "$pref" ]; then
            ip -4 rule del pref "$pref" fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE" 2>/dev/null || true
        fi
        if grep -q '^ROUTE_CREATED=1$' "$TPROXY_STATE_FILE" && [ -n "$interface" ]; then
            ip -4 route del local default dev "$interface" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true
        fi
    fi
}

clean_owned_table sing-box-tun "$TUN_STATE_FILE" TUN || exit 1
clean_tproxy_routes
clean_owned_table sing-box "$TPROXY_STATE_FILE" TProxy || exit 1
rm -f /etc/sing-box/tun/nftables.conf
rmdir /etc/sing-box/tun 2>/dev/null || true

echo "sing-box 服务已停止，Sbshell 管理的 TProxy/TUN 防火墙状态已清理。"
