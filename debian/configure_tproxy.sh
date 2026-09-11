#!/bin/sh
set -eu

TPROXY_PORT=7895
ROUTING_MARK=666
PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100
INTERFACE=$(ip route show default | awk '/default/ {print $5; exit}')
[ -n "$INTERFACE" ] || { echo "无法确定默认网卡" >&2; exit 1; }

ReservedIP4='{ 127.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 198.51.100.0/24, 192.88.99.0/24, 192.168.0.0/16, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4, 255.255.255.255/32 }'
CustomBypassIP='{ 192.168.0.0/16, 10.0.0.0/8 }'
MODE=$(grep -oP '(?<=^MODE=).*' /etc/sing-box/mode.conf 2>/dev/null || true)

if [ "$MODE" != "TProxy" ]; then
    echo "当前模式为 TUN 模式，不需要应用 TProxy 防火墙规则。"
    exit 0
fi

NFT_DIR=/etc/sing-box/nft
NFT_FILE="$NFT_DIR/nftables.conf"
mkdir -p "$NFT_DIR"

cat > "$NFT_FILE.tmp" <<EOF
table inet sing-box {
    set RESERVED_IPSET {
        type ipv4_addr
        flags interval
        auto-merge
        elements = $ReservedIP4
    }
    chain prerouting_tproxy {
        type filter hook prerouting priority mangle; policy accept;
        meta l4proto { tcp, udp } th dport 53 tproxy to :$TPROXY_PORT accept
        ip daddr $CustomBypassIP accept
        fib daddr type local meta l4proto { tcp, udp } th dport $TPROXY_PORT reject with icmpx type host-unreachable
        fib daddr type local accept
        ip daddr @RESERVED_IPSET accept
        meta l4proto tcp socket transparent 1 meta mark set $PROXY_FWMARK accept
        meta l4proto { tcp, udp } tproxy to :$TPROXY_PORT meta mark set $PROXY_FWMARK
    }
    chain output_tproxy {
        type route hook output priority mangle; policy accept;
        meta oifname "lo" accept
        meta mark $ROUTING_MARK accept
        meta l4proto { tcp, udp } th dport 53 meta mark set $PROXY_FWMARK
        udp dport { netbios-ns, netbios-dgm, netbios-ssn } accept
        ip daddr $CustomBypassIP accept
        fib daddr type local accept
        ip daddr @RESERVED_IPSET accept
        meta l4proto { tcp, udp } meta mark set $PROXY_FWMARK
    }
}
EOF

nft -c -f "$NFT_FILE.tmp"

old_rules=$(mktemp)
trap 'rm -f "$old_rules" "$NFT_FILE.tmp"' EXIT
nft list table inet sing-box > "$old_rules" 2>/dev/null || true
OLD_RULE_LINE=$(ip -4 rule show | awk -v mark="$PROXY_FWMARK" -v table="$PROXY_ROUTE_TABLE" '$0 ~ ("fwmark 0x" mark) && $0 ~ ("lookup " table) {print; exit}')
OLD_RULE_PREF=${OLD_RULE_LINE%%:*}
OLD_RULE_SPEC=${OLD_RULE_LINE#*: }
OLD_ROUTE=$(ip -4 route show table "$PROXY_ROUTE_TABLE" | awk -v ifc="$INTERFACE" '$0 == "local default dev " ifc || index($0, "local default dev " ifc " ") == 1 {print; exit}')
RULE_WAS_PRESENT=0
ROUTE_WAS_PRESENT=0
[ -n "$OLD_RULE_LINE" ] && RULE_WAS_PRESENT=1
[ -n "$OLD_ROUTE" ] && ROUTE_WAS_PRESENT=1
CREATED_RULE=0
CREATED_ROUTE=0

rollback() {
    nft delete table inet sing-box 2>/dev/null || true
    if [ -s "$old_rules" ]; then nft -f "$old_rules" 2>/dev/null || true; fi
    if [ "$CREATED_RULE" -eq 1 ]; then ip -4 rule del fwmark "$PROXY_FWMARK" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true; fi
    if [ "$CREATED_ROUTE" -eq 1 ]; then ip -4 route del local default dev "$INTERFACE" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true; fi
    if [ "$RULE_WAS_PRESENT" -eq 1 ]; then
        ip -4 rule show | grep -Fq "$OLD_RULE_SPEC" || ip -4 rule add pref "$OLD_RULE_PREF" $OLD_RULE_SPEC 2>/dev/null || true
    fi
    if [ "$ROUTE_WAS_PRESENT" -eq 1 ]; then
        ip -4 route show table "$PROXY_ROUTE_TABLE" | grep -Fqx "$OLD_ROUTE" || ip -4 route add table "$PROXY_ROUTE_TABLE" $OLD_ROUTE 2>/dev/null || true
    fi
}

if [ "$ROUTE_WAS_PRESENT" -eq 0 ]; then
    if ! ip -4 route add local default dev "$INTERFACE" table "$PROXY_ROUTE_TABLE"; then rollback; exit 1; fi
    CREATED_ROUTE=1
fi
if [ "$RULE_WAS_PRESENT" -eq 0 ]; then
    if ! ip -4 rule add fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE"; then rollback; exit 1; fi
    CREATED_RULE=1
fi
if ! nft -f "$NFT_FILE.tmp"; then
    rollback
    exit 1
fi

mv "$NFT_FILE.tmp" "$NFT_FILE"
sysctl -w net.ipv4.ip_forward=1 >/dev/null

echo "TProxy 模式的防火墙规则已安全应用。"
