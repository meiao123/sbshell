#!/bin/sh
set -eu
TPROXY_PORT=7895
ROUTING_MARK=666
PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100
INTERFACE=$(ip route show default | awk '/default/ {print $5; exit}')
MODE=$(sed -n 's/^MODE=//p' /etc/sing-box/mode.conf 2>/dev/null | head -n1)
[ "$MODE" = TProxy ] || exit 0
[ -n "$INTERFACE" ] || { echo '未找到默认网卡。' >&2; exit 1; }
command -v nft >/dev/null 2>&1 || { echo '缺少 nft。' >&2; exit 1; }

RESERVED='{ 127.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 198.51.100.0/24, 192.168.0.0/16, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4, 255.255.255.255/32 }'
BYPASS='{ 192.168.0.0/16, 10.0.0.0/8 }'
TMP=$(mktemp /tmp/sbshell-nft.XXXXXX)
OLD=$(mktemp /tmp/sbshell-ruleset.XXXXXX)
trap 'rm -f "$TMP" "$OLD"' EXIT

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
nft list table inet sing-box > "$OLD" 2>/dev/null || true

nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box || true
ip rule del fwmark "$PROXY_FWMARK" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true
ip route del local default dev "$INTERFACE" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true

rollback() {
    nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box || true
    [ ! -s "$OLD" ] || nft -f "$OLD" 2>/dev/null || true
    ip rule del fwmark "$PROXY_FWMARK" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true
    ip route del local default dev "$INTERFACE" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true
}

if ! ip route add local default dev "$INTERFACE" table "$PROXY_ROUTE_TABLE"; then rollback; exit 1; fi
if ! ip -f inet rule add fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE"; then rollback; exit 1; fi
if ! nft -f "$TMP"; then rollback; exit 1; fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null
nft list ruleset > /etc/nftables.conf
echo 'TProxy 模式防火墙规则已安全应用。'
