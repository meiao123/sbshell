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
STATE_FILE=/etc/sing-box/tun.state
TMP=$(mktemp /tmp/sbshell-tun.XXXXXX)
OLD_TUN_TABLE=$(mktemp /tmp/sbshell-tun-table.XXXXXX)
OLD_TUN_STATE=$(mktemp /tmp/sbshell-tun-state.XXXXXX)
trap 'rm -f "$TMP" "$OLD_TUN_TABLE" "$OLD_TUN_STATE"' EXIT
mkdir -p "$NFT_DIR"

if nft list table inet sing-box-tun > "$OLD_TUN_TABLE" 2>/dev/null; then
    if [ -f "$STATE_FILE" ] && grep -q '^OWNER=sbshell$' "$STATE_FILE"; then
        cp "$STATE_FILE" "$OLD_TUN_STATE"
        nft delete table inet sing-box-tun
    else
        echo '检测到非 Sbshell 管理的 inet sing-box-tun 表，拒绝覆盖。' >&2
        exit 1
    fi
else
    : > "$OLD_TUN_TABLE"
    : > "$OLD_TUN_STATE"
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
    [ ! -s "$OLD_TUN_STATE" ] || { install -o root -g root -m 0600 "$OLD_TUN_STATE" "$STATE_FILE"; }
    exit 1
fi

install -o root -g root -m 0644 "$TMP" "$NFT_FILE"
cat > "$STATE_FILE" <<EOF
OWNER=sbshell
MODE=TUN
TUN_TABLE_CREATED=1
INTERFACE=$INTERFACE
EOF
chown root:root "$STATE_FILE"
chmod 0600 "$STATE_FILE"
echo 'TUN 模式防火墙规则已安全应用。'
