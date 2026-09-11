#!/bin/bash
set -Eeuo pipefail

PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100
INTERFACE=$(ip route show default | awk '/default/ {print $5; exit}')
MODE=$(sed -n 's/^MODE=//p' /etc/sing-box/mode.conf 2>/dev/null | head -n1)
[ "$MODE" = TUN ] || exit 0
[ -n "$INTERFACE" ] || { echo '无法确定默认网卡。' >&2; exit 1; }
command -v nft >/dev/null 2>&1 || { echo '缺少 nft。' >&2; exit 1; }

NFT_DIR=/etc/sing-box/tun
NFT_FILE="$NFT_DIR/nftables.conf"
TMP=$(mktemp /tmp/sbshell-tun.XXXXXX)
OLD_NFT=$(mktemp /tmp/sbshell-tun-ruleset.XXXXXX)
OLD_RULE=$(mktemp /tmp/sbshell-tun-rule.XXXXXX)
OLD_ROUTE=$(mktemp /tmp/sbshell-tun-route.XXXXXX)
STATE_FILE=/etc/sing-box/tproxy.state
trap 'rm -f "$TMP" "$OLD_NFT" "$OLD_RULE" "$OLD_ROUTE"' EXIT
mkdir -p "$NFT_DIR"

# Snapshot everything before any destructive operation.
nft list ruleset > "$OLD_NFT" 2>/dev/null || true
ip -4 rule show > "$OLD_RULE" 2>/dev/null || true
ip -4 route show table "$PROXY_ROUTE_TABLE" > "$OLD_ROUTE" 2>/dev/null || true

# Only remove a TProxy rule/table that was explicitly created by Sbshell.
if [ -f "$STATE_FILE" ] && grep -q '^OWNER=sbshell$' "$STATE_FILE"; then
    nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box || true
    grep -q '^RULE_CREATED=1$' "$STATE_FILE" && ip -4 rule del fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE" 2>/dev/null || true
    OLD_INTERFACE=$(sed -n 's/^INTERFACE=//p' "$STATE_FILE" | head -n1)
    [ -n "$OLD_INTERFACE" ] || OLD_INTERFACE="$INTERFACE"
    grep -q '^ROUTE_CREATED=1$' "$STATE_FILE" && ip -4 route del local default dev "$OLD_INTERFACE" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true
fi

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
    nft -f "$OLD_NFT" 2>/dev/null || true
    # Restore policy routing state exactly as it existed before this run.
    ip -4 rule flush 2>/dev/null || true
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        spec=${line#*: }
        pref=${line%%:*}
        [ -n "$spec" ] || continue
        ip -4 rule add pref "$pref" $spec 2>/dev/null || true
done < "$OLD_RULE"
    ip -4 route flush table "$PROXY_ROUTE_TABLE" 2>/dev/null || true
    while IFS= read -r route; do
        [ -n "$route" ] || continue
        ip -4 route add table "$PROXY_ROUTE_TABLE" $route 2>/dev/null || true
done < "$OLD_ROUTE"
    exit 1
fi

install -o root -g root -m 0644 "$TMP" "$NFT_FILE"
rm -f "$STATE_FILE"

echo 'TUN 模式防火墙规则已应用。'
