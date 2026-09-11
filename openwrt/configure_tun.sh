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
TUN_STATE_FILE=/etc/sing-box/tun.state
TPROXY_STATE_FILE=/etc/sing-box/tproxy.state
TMP=$(mktemp /tmp/sbshell-tun.XXXXXX)
OLD_TUN_TABLE=$(mktemp /tmp/sbshell-tun-table.XXXXXX)
OLD_TUN_STATE=$(mktemp /tmp/sbshell-tun-state.XXXXXX)
OLD_TPROXY_TABLE=$(mktemp /tmp/sbshell-tproxy-table.XXXXXX)
OLD_TPROXY_STATE=$(mktemp /tmp/sbshell-tproxy-state.XXXXXX)
OLD_RULE=$(mktemp /tmp/sbshell-tun-rule.XXXXXX)
OLD_ROUTE=$(mktemp /tmp/sbshell-tun-route.XXXXXX)
trap 'rm -f "$TMP" "$OLD_TUN_TABLE" "$OLD_TUN_STATE" "$OLD_TPROXY_TABLE" "$OLD_TPROXY_STATE" "$OLD_RULE" "$OLD_ROUTE"' EXIT
mkdir -p "$NFT_DIR" /etc/sing-box

ip -4 rule show > "$OLD_RULE" 2>/dev/null || true
ip -4 route show table "$PROXY_ROUTE_TABLE" > "$OLD_ROUTE" 2>/dev/null || true

if nft list table inet sing-box-tun > "$OLD_TUN_TABLE" 2>/dev/null; then
    if [ -f "$TUN_STATE_FILE" ] && grep -q '^OWNER=sbshell$' "$TUN_STATE_FILE"; then
        cp "$TUN_STATE_FILE" "$OLD_TUN_STATE"
        nft delete table inet sing-box-tun
    else
        echo '检测到非 Sbshell 管理的 inet sing-box-tun 表，拒绝覆盖。' >&2
        exit 1
    fi
else
    : > "$OLD_TUN_TABLE"
    : > "$OLD_TUN_STATE"
fi

if nft list table inet sing-box > "$OLD_TPROXY_TABLE" 2>/dev/null; then
    if [ -f "$TPROXY_STATE_FILE" ] && grep -q '^OWNER=sbshell$' "$TPROXY_STATE_FILE"; then
        cp "$TPROXY_STATE_FILE" "$OLD_TPROXY_STATE"
        nft delete table inet sing-box
    else
        echo '检测到非 Sbshell 管理的 inet sing-box 表，拒绝覆盖。' >&2
        [ ! -s "$OLD_TUN_TABLE" ] || nft -f "$OLD_TUN_TABLE" 2>/dev/null || true
        exit 1
    fi
else
    : > "$OLD_TPROXY_TABLE"
    : > "$OLD_TPROXY_STATE"
fi

if [ -s "$OLD_TPROXY_STATE" ]; then
    old_pref=$(sed -n 's/^RULE_PREF=//p' "$TPROXY_STATE_FILE" | head -n1)
    old_interface=$(sed -n 's/^INTERFACE=//p' "$TPROXY_STATE_FILE" | head -n1)
    [ -n "$old_interface" ] || old_interface="$INTERFACE"
    if grep -q '^RULE_CREATED=1$' "$TPROXY_STATE_FILE" && [ -n "$old_pref" ]; then
        ip -4 rule del pref "$old_pref" fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE" 2>/dev/null || true
    fi
    if grep -q '^ROUTE_CREATED=1$' "$TPROXY_STATE_FILE"; then
        ip -4 route del local default dev "$old_interface" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true
    fi
    rm -f "$TPROXY_STATE_FILE"
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
    [ ! -s "$OLD_TUN_TABLE" ] || nft -f "$OLD_TUN_TABLE" 2>/dev/null || true
    [ ! -s "$OLD_TPROXY_TABLE" ] || nft -f "$OLD_TPROXY_TABLE" 2>/dev/null || true
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        spec=${line#*: }
        pref=${line%%:*}
        [ -n "$spec" ] || continue
        ip -4 rule show | grep -Fq "$spec" || ip -4 rule add pref "$pref" $spec 2>/dev/null || true
done < "$OLD_RULE"
    while IFS= read -r route; do
        [ -n "$route" ] || continue
        ip -4 route show table "$PROXY_ROUTE_TABLE" | grep -Fqx "$route" || ip -4 route add table "$PROXY_ROUTE_TABLE" $route 2>/dev/null || true
done < "$OLD_ROUTE"
    if [ -s "$OLD_TUN_STATE" ]; then install -o root -g root -m 0600 "$OLD_TUN_STATE" "$TUN_STATE_FILE"; else rm -f "$TUN_STATE_FILE"; fi
    if [ -s "$OLD_TPROXY_STATE" ]; then install -o root -g root -m 0600 "$OLD_TPROXY_STATE" "$TPROXY_STATE_FILE"; else rm -f "$TPROXY_STATE_FILE"; fi
    exit 1
fi

install -o root -g root -m 0644 "$TMP" "$NFT_FILE"
cat > "$TUN_STATE_FILE" <<EOF
OWNER=sbshell
MODE=TUN
TUN_TABLE_CREATED=1
INTERFACE=$INTERFACE
EOF
chown root:root "$TUN_STATE_FILE"
chmod 0600 "$TUN_STATE_FILE"
echo 'TUN 模式防火墙规则已安全应用。'
