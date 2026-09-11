#!/bin/bash
set -Eeuo pipefail
TPROXY_PORT=7895; ROUTING_MARK=666; PROXY_FWMARK=1; PROXY_ROUTE_TABLE=100; RULE_PREF=10010
INTERFACE=$(ip route show default | awk '/default/ {print $5; exit}')
MODE=$(sed -n 's/^MODE=//p' /etc/sing-box/mode.conf 2>/dev/null | head -n1)
[ "$MODE" = TProxy ] || exit 0
[ -n "$INTERFACE" ] || { echo '无法确定默认网卡。' >&2; exit 1; }
command -v nft >/dev/null 2>&1 || { echo '缺少 nft。' >&2; exit 1; }
RESERVED='{ 127.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 198.51.100.0/24, 192.168.0.0/16, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4, 255.255.255.255/32 }'
BYPASS='{ 192.168.0.0/16, 10.0.0.0/8 }'
NFT_TMP=$(mktemp /tmp/sbshell-tproxy.XXXXXX); OLD_NFT=$(mktemp /tmp/sbshell-tproxy-ruleset.XXXXXX); STATE_FILE=/etc/sing-box/tproxy.state
trap 'rm -f "$NFT_TMP" "$OLD_NFT"' EXIT
cat > "$NFT_TMP" <<EOF
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
nft -c -f "$NFT_TMP"
mkdir -p /etc/sing-box
nft list ruleset > "$OLD_NFT" 2>/dev/null || true
if [ -f "$STATE_FILE" ] && grep -q '^OWNER=sbshell$' "$STATE_FILE"; then
    nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box || true
    if grep -q '^RULE_CREATED=1$' "$STATE_FILE"; then ip -4 rule del pref "$(sed -n 's/^RULE_PREF=//p' "$STATE_FILE" | head -n1)" fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE" 2>/dev/null || true; fi
    OLD_INTERFACE=$(sed -n 's/^INTERFACE=//p' "$STATE_FILE" | head -n1); [ -n "$OLD_INTERFACE" ] || OLD_INTERFACE="$INTERFACE"
    if grep -q '^ROUTE_CREATED=1$' "$STATE_FILE"; then ip -4 route del local default dev "$OLD_INTERFACE" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true; fi
fi
RULE_CREATED=0; ROUTE_CREATED=0; ACTUAL_RULE_PREF=''
ACTUAL_RULE_PREF=$(ip -4 rule show | awk -v mark="$PROXY_FWMARK" -v table="$PROXY_ROUTE_TABLE" '$0 ~ ("fwmark 0x" mark) && $0 ~ ("lookup " table) {sub(/:.*/, ""); print; exit}')
if [ -z "$ACTUAL_RULE_PREF" ]; then
    ip -4 rule add pref "$RULE_PREF" fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE"; RULE_CREATED=1; ACTUAL_RULE_PREF="$RULE_PREF"
fi
if ! ip -4 route show table "$PROXY_ROUTE_TABLE" | awk -v ifc="$INTERFACE" '$0 == "local default dev " ifc || index($0, "local default dev " ifc " ") == 1 {found=1} END {exit !found}'; then
    ip -4 route add local default dev "$INTERFACE" table "$PROXY_ROUTE_TABLE"; ROUTE_CREATED=1
fi
if nft list table inet sing-box >/dev/null 2>&1; then
    echo '检测到非 Sbshell 管理的 inet sing-box 表，拒绝覆盖。' >&2
    [ "$RULE_CREATED" -eq 0 ] || ip -4 rule del pref "$RULE_PREF" fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE" 2>/dev/null || true
    [ "$ROUTE_CREATED" -eq 0 ] || ip -4 route del local default dev "$INTERFACE" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true
    exit 1
fi
if ! nft -f "$NFT_TMP"; then
    nft -f "$OLD_NFT" 2>/dev/null || true
    [ "$RULE_CREATED" -eq 0 ] || ip -4 rule del pref "$RULE_PREF" fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE" 2>/dev/null || true
    [ "$ROUTE_CREATED" -eq 0 ] || ip -4 route del local default dev "$INTERFACE" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true
    exit 1
fi
cat > "$STATE_FILE" <<EOF
OWNER=sbshell
INTERFACE=$INTERFACE
RULE_PREF=$ACTUAL_RULE_PREF
RULE_CREATED=$RULE_CREATED
ROUTE_CREATED=$ROUTE_CREATED
EOF
chown root:root "$STATE_FILE"; chmod 0600 "$STATE_FILE"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo 'TProxy 模式的防火墙规则已安全应用。'
