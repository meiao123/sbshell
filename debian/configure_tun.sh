#!/bin/bash
set -Eeuo pipefail

PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100
INTERFACE=$(ip route show default | awk '/default/ {print $5; exit}')
MODE=$(sed -n 's/^MODE=//p' /etc/sing-box/mode.conf 2>/dev/null | head -n1)
[ "$MODE" = TUN ] || exit 0
[ -n "$INTERFACE" ] || { echo '无法确定默认网卡。' >&2; exit 1; }
command -v nft >/dev/null 2>&1 || { echo '缺少 nft。' >&2; exit 1; }

# TUN 模式不需要 TProxy 路由/规则；仅移除本项目自己的表和策略。
nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box || true
ip rule del fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE" 2>/dev/null || true
ip route del local default dev "$INTERFACE" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true

NFT_DIR=/etc/sing-box/tun
NFT_FILE="$NFT_DIR/nftables.conf"
TMP=$(mktemp "$NFT_DIR/.nftables.conf.XXXXXX")
OLD=$(mktemp /tmp/sbshell-tun-ruleset.XXXXXX)
trap 'rm -f "$TMP" "$OLD"' EXIT
mkdir -p "$NFT_DIR"
nft list ruleset > "$OLD" 2>/dev/null || true

cat > "$TMP" <<'EOF'
table inet sing-box-tun {
    chain input { type filter hook input priority 0; policy accept; }
    chain forward { type filter hook forward priority 0; policy accept; }
    chain output { type filter hook output priority 0; policy accept; }
}
EOF
nft -c -f "$TMP"
if ! nft -f "$TMP"; then
    nft list table inet sing-box-tun >/dev/null 2>&1 && nft delete table inet sing-box-tun || true
    nft -f "$OLD" 2>/dev/null || true
    exit 1
fi
install -o root -g root -m 0644 "$TMP" "$NFT_FILE"
nft list ruleset > /etc/nftables.conf

echo 'TUN 模式防火墙规则已应用。'
