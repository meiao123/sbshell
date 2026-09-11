#!/bin/sh
set -eu
TPROXY_PORT=7895
ROUTING_MARK=666
PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100
RULE_PREF=10010
INTERFACE=$(ip route show default | awk '/default/ {print $5; exit}')
MODE=$(sed -n 's/^MODE=//p' /etc/sing-box/mode.conf 2>/dev/null | head -n1)
[ "$MODE" = TProxy ] || exit 0
[ -n "$INTERFACE" ] || { echo '未找到默认网卡。' >&2; exit 1; }
command -v nft >/dev/null 2>&1 || { echo '缺少 nft。' >&2; exit 1; }
RESERVED='{ 127.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 198.51.100.0/24, 192.168.0.0/16, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4, 255.255.255.255/32 }'
BYPASS='{ 192.168.0.0/16, 10.0.0.0/8 }'
TMP=$(mktemp /tmp/sbshell-tproxy.XXXXXX)
OLD_TABLE=$(mktemp /tmp/sbshell-tproxy-table.XXXXXX)
OLD_TUN_TABLE=$(mktemp /tmp/sbshell-tun-table.XXXXXX)
OLD_TUN_STATE=$(mktemp /tmp/sbshell-tun-state.XXXXXX)
STATE_FILE=/etc/sing-box/tproxy.state
TUN_STATE_FILE=/etc/sing-box/tun.state
TUN_NFT_FILE=/etc/sing-box/tun/nftables.conf
trap 'rm -f "$TMP" "$OLD_TABLE" "$OLD_TUN_TABLE" "$OLD_TUN_STATE"' EXIT
mkdir -p /etc/sing-box

cat > "$TMP" <<EOF
table inet sing-box {
 set RESERVED_IPSET { type ipv4_addr; flags interval; auto-merge; elements = $RESERVED }
 chain prerouting_tproxy { type filter hook prerouting priority mangle; policy accept;
  meta l4proto { tcp, udp } th dport 53 tproxy to :$TPROXY_PORT accept
  ip daddr $BYPASS accept
  fib daddr type local meta l4proto { tcp, udp } th dport $TPROXY_PORT reject with icmpx type host-unreachable
  fib daddr type local accept
  ip daddr @RESERVED_IPSET accept
  ct status dnat accept
  meta l4proto { tcp, udp } tproxy to :$TPROXY_PORT meta mark set $PROXY_FWMARK
 }
 chain output_tproxy { type route hook output priority mangle; policy accept;
  meta oifname "lo" accept
  meta mark $ROUTING_MARK accept
  meta l4proto { tcp, udp } th dport 53 meta mark set $PROXY_FWMARK
  udp dport { netbios-ns, netbios-dgm, netbios-ssn } accept
  ip daddr $BYPASS accept
  fib daddr type local accept
  ip daddr @RESERVED_IPSET accept
  meta l4proto { tcp, udp } meta mark set $PROXY_FWMARK
 }
}
EOF
nft -c -f "$TMP"

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

RULE_CREATED=0
ROUTE_CREATED=0
RULE_OWNED=0
ROUTE_OWNED=0
if [ -f "$STATE_FILE" ] && grep -q '^OWNER=sbshell$' "$STATE_FILE"; then
    nft list table inet sing-box > "$OLD_TABLE" 2>/dev/null || true
    prior_rule_created=0
    prior_route_created=0
    prior_rule_owned=0
    prior_route_owned=0
    grep -q '^RULE_CREATED=1$' "$STATE_FILE" && prior_rule_created=1
    grep -q '^ROUTE_CREATED=1$' "$STATE_FILE" && prior_route_created=1
    grep -q '^RULE_OWNED=1$' "$STATE_FILE" && prior_rule_owned=1
    grep -q '^ROUTE_OWNED=1$' "$STATE_FILE" && prior_route_owned=1
    # Backward compatibility with old state files: RULE_CREATED=1/ROUTE_CREATED=1 implied Sbshell ownership.
    [ "$prior_rule_owned" -eq 1 ] || [ "$prior_rule_created" -eq 1 ] && prior_rule_owned=1
    [ "$prior_route_owned" -eq 1 ] || [ "$prior_route_created" -eq 1 ] && prior_route_owned=1
    if [ "$prior_rule_owned" -eq 1 ]; then
        old_pref=$(sed -n 's/^RULE_PREF=//p' "$STATE_FILE" | head -n1)
        [ -n "$old_pref" ] && ip -4 rule del pref "$old_pref" fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE" 2>/dev/null || true
    fi
    OLD_INTERFACE=$(sed -n 's/^INTERFACE=//p' "$STATE_FILE" | head -n1); [ -n "$OLD_INTERFACE" ] || OLD_INTERFACE="$INTERFACE"
    if [ "$prior_route_owned" -eq 1 ]; then ip -4 route del local default dev "$OLD_INTERFACE" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true; fi
    nft delete table inet sing-box 2>/dev/null || true
    RULE_OWNED=$prior_rule_owned
    ROUTE_OWNED=$prior_route_owned
else
    : > "$OLD_TABLE"
    prior_rule_created=0
    prior_route_created=0
    prior_rule_owned=0
    prior_route_owned=0
fi

rollback() {
    if [ "$RULE_CREATED" -eq 1 ]; then ip -4 rule del pref "$ACTUAL_RULE_PREF" fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE" 2>/dev/null || true; fi
    if [ "$ROUTE_CREATED" -eq 1 ]; then ip -4 route del local default dev "$INTERFACE" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true; fi
    if [ -s "$OLD_TABLE" ]; then
        nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box || true
        nft -f "$OLD_TABLE" 2>/dev/null || true
    fi
    nft list table inet sing-box-tun >/dev/null 2>&1 && nft delete table inet sing-box-tun || true
    if [ -s "$OLD_TUN_TABLE" ]; then
        nft -f "$OLD_TUN_TABLE" 2>/dev/null || true
        [ ! -s "$OLD_TUN_STATE" ] || install -o root -g root -m 0600 "$OLD_TUN_STATE" "$TUN_STATE_FILE"
    else
        rm -f "$TUN_STATE_FILE"
    fi
}

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

ACTUAL_RULE_PREF=$(rule_pref_for_mark "$PROXY_FWMARK" "$PROXY_ROUTE_TABLE")
if [ -z "$ACTUAL_RULE_PREF" ]; then
    if ! ip -4 rule add pref "$RULE_PREF" fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE"; then rollback; exit 1; fi
    RULE_CREATED=1
    RULE_OWNED=1
    ACTUAL_RULE_PREF="$RULE_PREF"
fi
if ! ip -4 route show table "$PROXY_ROUTE_TABLE" | awk -v ifc="$INTERFACE" '$0 == "local default dev " ifc || index($0, "local default dev " ifc " ") == 1 {found=1} END {exit !found}'; then
    if ! ip -4 route add local default dev "$INTERFACE" table "$PROXY_ROUTE_TABLE"; then rollback; exit 1; fi
    ROUTE_CREATED=1
    ROUTE_OWNED=1
fi

if nft list table inet sing-box >/dev/null 2>&1; then
    echo '检测到非 Sbshell 管理的 inet sing-box 表，拒绝覆盖。' >&2
    rollback
    exit 1
fi
if ! nft -f "$TMP"; then
    rollback
    exit 1
fi

if [ "$prior_rule_created" -eq 1 ]; then RULE_CREATED=0; fi
if [ "$prior_route_created" -eq 1 ] && [ "$ROUTE_CREATED" -eq 0 ]; then ROUTE_CREATED=0; fi
cat > "$STATE_FILE" <<EOF
OWNER=sbshell
MODE=TProxy
TUN_TABLE_CREATED=0
INTERFACE=$INTERFACE
RULE_PREF=$ACTUAL_RULE_PREF
RULE_CREATED=$RULE_CREATED
ROUTE_CREATED=$ROUTE_CREATED
RULE_OWNED=$RULE_OWNED
ROUTE_OWNED=$ROUTE_OWNED
EOF
chown root:root "$STATE_FILE"; chmod 0600 "$STATE_FILE"
rm -f "$TUN_STATE_FILE" "$TUN_NFT_FILE"
echo 'TProxy 模式防火墙规则已安全应用。'
