#!/bin/bash
set -eu
# 这里必须是 bash：下面依赖 `trap ... ERR` 才能在**未预期**失败时回滚，而 POSIX sh/busybox ash
# 不支持 ERR trap（SC3047）。所有调用方（manage_autostart.sh、start_singbox.sh、menu.sh）
# 本来就是 `bash <脚本>` 调用，改 shebang 与实际执行方式一致。

# 公共实现（install 兜底、防火墙参数）集中在 lib.sh，避免三份副本漂移。
_sbshell_lib_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$_sbshell_lib_dir/lib.sh" || { echo '缺少 lib.sh，请先在菜单 9 更新脚本。' >&2; exit 1; }

# 两阶段提交：pending 文件也代表「本次/上次是 Sbshell 在建表」，崩溃后仍可回收。
fw_owned() { # $1=state 文件
    { [ -f "$1" ] && grep -q '^OWNER=sbshell$' "$1"; } ||
    { [ -f "$1.pending" ] && grep -q '^OWNER=sbshell$' "$1.pending"; } ||
    { [ -f "$1" ] && grep -q '^PENDING=1$' "$1"; }
}

# 按 "dev" 关键字取默认路由出口网卡：PPPoE/WireGuard 的 dev-only 默认路由取 $5 会得到 "link"。
INTERFACE=$(ip route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
MODE=$(sed -n 's/^MODE=//p' /etc/sing-box/mode.conf 2>/dev/null | head -n1)
[ "$MODE" = TProxy ] || exit 0
[ -n "$INTERFACE" ] || { echo '未找到默认网卡。' >&2; exit 1; }
command -v nft >/dev/null 2>&1 || { echo '缺少 nft。' >&2; exit 1; }

# A3：端口以 config.json 里 tproxy inbound 的 listen_port 为准（简单花括号配对），
# 避免模板改了端口而防火墙仍写死导致流量落到没人监听的端口。
CONFIG_FILE=/etc/sing-box/config.json
TPROXY_PORT=''
if [ -f "$CONFIG_FILE" ]; then
    TPROXY_PORT=$(awk '
        { buf = buf $0 "\n" }
        END {
            n = length(buf)
            depth = 0
            for (i = 1; i <= n; i++) {
                c = substr(buf, i, 1)
                if (c == "\"") {
                    i++
                    while (i <= n) {
                        c = substr(buf, i, 1)
                        if (c == "\\") i++
                        else if (c == "\"") break
                        i++
                    }
                    continue
                }
                if (c == "{") { depth++; stack[depth] = i }
                else if (c == "}" && depth > 0) {
                    obj = substr(buf, stack[depth], i - stack[depth] + 1)
                    depth--
                    if (obj ~ /"type"[[:space:]]*:[[:space:]]*"tproxy"/ &&
                        match(obj, /"listen_port"[[:space:]]*:[[:space:]]*[0-9]+/)) {
                        seg = substr(obj, RSTART, RLENGTH)
                        sub(/.*:[[:space:]]*/, "", seg)
                        print seg
                        exit
                    }
                }
            }
        }
    ' "$CONFIG_FILE" 2>/dev/null || true)
fi
case "$TPROXY_PORT" in
    ''|*[!0-9]*)
        TPROXY_PORT=7895
        echo '未在 config.json 中找到 tproxy inbound，按 7895 下发规则。' >&2
        ;;
esac

# A4：nft/ip 变更前加锁，避免并发切换/清理互相拆表；没有 flock 时静默跳过（保持旧行为）。
LOCK_FILE=/var/lock/sbshell-firewall.lock
mkdir -p /var/lock
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -w 20 9 || { echo '另一个防火墙操作正在进行，请稍后重试。' >&2; exit 1; }
fi

STATE_FILE=/etc/sing-box/tproxy.state
# 两阶段提交的 pending 标记：建表**之前**落盘，state 落盘之后删除（崩溃后可据此回收表）。
STATE_PENDING="$STATE_FILE.pending"
TUN_STATE_FILE=/etc/sing-box/tun.state
TUN_NFT_FILE=/etc/sing-box/tun/nftables.conf
# A-18：先装清理 trap、再创建临时文件（每个都检查），cleanup 内一律用 ${VAR:-} 保护 ——
# 反过来写时，中途失败会残留 /tmp（tmpfs 即内存），或 trap 引用未赋值变量在 set -u 下二次报错。
TMP=''
OLD_TABLE=''
OLD_TUN_TABLE=''
OLD_TUN_STATE=''
STATE_TMP=''
PENDING_TMP=''
cleanup() {
    [ -z "${TMP:-}" ] || rm -f "$TMP"
    [ -z "${OLD_TABLE:-}" ] || rm -f "$OLD_TABLE"
    [ -z "${OLD_TUN_TABLE:-}" ] || rm -f "$OLD_TUN_TABLE"
    [ -z "${OLD_TUN_STATE:-}" ] || rm -f "$OLD_TUN_STATE"
    [ -z "${STATE_TMP:-}" ] || rm -f "$STATE_TMP"
    [ -z "${PENDING_TMP:-}" ] || rm -f "$PENDING_TMP"
}
trap cleanup EXIT
tmp_fail() { echo '无法创建临时文件（/tmp 是否可写？）。' >&2; exit 1; }
TMP=$(mktemp /tmp/sbshell-tproxy.XXXXXX) || tmp_fail
OLD_TABLE=$(mktemp /tmp/sbshell-tproxy-table.XXXXXX) || tmp_fail
OLD_TUN_TABLE=$(mktemp /tmp/sbshell-tun-table.XXXXXX) || tmp_fail
OLD_TUN_STATE=$(mktemp /tmp/sbshell-tun-state.XXXXXX) || tmp_fail
mkdir -p /etc/sing-box

# A1：TProxy 目前只代理 IPv4（模板只监听 0.0.0.0），两条链首行显式放行 v6，
# 避免 v6 流量落到没有监听的 tproxy 端口、处于"半代理"状态。
cat > "$TMP" <<EOF
table inet sing-box {
 set RESERVED_IPSET { type ipv4_addr; flags interval; auto-merge; elements = $SBSHELL_RESERVED_V4 }
 chain prerouting_tproxy { type filter hook prerouting priority mangle; policy accept;
  meta nfproto ipv6 return
  meta l4proto { tcp, udp } th dport 53 tproxy to :$TPROXY_PORT accept
  ip daddr $SBSHELL_BYPASS_V4 accept
  fib daddr type local meta l4proto { tcp, udp } th dport $TPROXY_PORT reject with icmpx type host-unreachable
  fib daddr type local accept
  ip daddr @RESERVED_IPSET accept
  ct status dnat accept
  meta l4proto { tcp, udp } tproxy to :$TPROXY_PORT meta mark set $SBSHELL_PROXY_FWMARK
 }
 chain output_tproxy { type route hook output priority mangle; policy accept;
  meta nfproto ipv6 return
  meta oifname "lo" accept
  meta mark $SBSHELL_ROUTING_MARK accept
  meta l4proto { tcp, udp } th dport 53 meta mark set $SBSHELL_PROXY_FWMARK
  udp dport { netbios-ns, netbios-dgm } accept
  tcp dport 139 accept
  ip daddr $SBSHELL_BYPASS_V4 accept
  fib daddr type local accept
  ip daddr @RESERVED_IPSET accept
  meta l4proto { tcp, udp } meta mark set $SBSHELL_PROXY_FWMARK
 }
}
EOF
nft -c -f "$TMP"

if nft list table inet sing-box-tun > "$OLD_TUN_TABLE" 2>/dev/null; then
    if fw_owned "$TUN_STATE_FILE"; then
        # 只有 pending、没有 state（上次在建表与落盘之间崩溃）时，字段从 pending 里取。
        OLD_TUN_STATE_SRC="$TUN_STATE_FILE"
        [ -f "$OLD_TUN_STATE_SRC" ] || OLD_TUN_STATE_SRC="$TUN_STATE_FILE.pending"
        cp "$OLD_TUN_STATE_SRC" "$OLD_TUN_STATE"
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
# 本次运行是否真的建出了 inet sing-box 表：回滚时据此决定要不要删除它（见 rollback）。
TABLE_CREATED=0
if fw_owned "$STATE_FILE"; then
    # 两阶段提交崩溃后可能只剩 pending（state 没写成）：所有字段都从 pending 读。
    STATE_SRC="$STATE_FILE"
    [ -f "$STATE_SRC" ] || STATE_SRC="$STATE_PENDING"
    nft list table inet sing-box > "$OLD_TABLE" 2>/dev/null || true
    prior_rule_created=0
    prior_route_created=0
    prior_rule_owned=0
    prior_route_owned=0
    grep -q '^RULE_CREATED=1$' "$STATE_SRC" && prior_rule_created=1
    grep -q '^ROUTE_CREATED=1$' "$STATE_SRC" && prior_route_created=1
    grep -q '^RULE_OWNED=1$' "$STATE_SRC" && prior_rule_owned=1
    grep -q '^ROUTE_OWNED=1$' "$STATE_SRC" && prior_route_owned=1
    # Backward compatibility with old state files: RULE_CREATED=1/ROUTE_CREATED=1 implied Sbshell ownership.
    [ "$prior_rule_owned" -eq 1 ] || [ "$prior_rule_created" -eq 1 ] && prior_rule_owned=1
    [ "$prior_route_owned" -eq 1 ] || [ "$prior_route_created" -eq 1 ] && prior_route_owned=1
    if [ "$prior_rule_owned" -eq 1 ]; then
        old_pref=$(sed -n 's/^RULE_PREF=//p' "$STATE_SRC" | head -n1)
        [ -n "$old_pref" ] && ip -4 rule del pref "$old_pref" fwmark "$SBSHELL_PROXY_FWMARK" lookup "$SBSHELL_ROUTE_TABLE" 2>/dev/null || true
    fi
    OLD_INTERFACE=$(sed -n 's/^INTERFACE=//p' "$STATE_SRC" | head -n1); [ -n "$OLD_INTERFACE" ] || OLD_INTERFACE="$INTERFACE"
    if [ "$prior_route_owned" -eq 1 ]; then ip -4 route del local default dev "$OLD_INTERFACE" table "$SBSHELL_ROUTE_TABLE" 2>/dev/null || true; fi
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
    if [ "$RULE_CREATED" -eq 1 ]; then ip -4 rule del pref "$ACTUAL_RULE_PREF" fwmark "$SBSHELL_PROXY_FWMARK" lookup "$SBSHELL_ROUTE_TABLE" 2>/dev/null || true; fi
    if [ "$ROUTE_CREATED" -eq 1 ]; then ip -4 route del local default dev "$INTERFACE" table "$SBSHELL_ROUTE_TABLE" 2>/dev/null || true; fi
    # 重新应用时旧 rule/route 已被删除：回滚时必须恢复，否则表恢复了但 TProxy 仍是坏的，
    # 而 state 文件仍声称 RULE_OWNED/ROUTE_OWNED=1。
    if [ "${prior_rule_owned:-0}" -eq 1 ] && [ -n "${old_pref:-}" ]; then
        [ -z "$(rule_pref_for_mark "$SBSHELL_PROXY_FWMARK" "$SBSHELL_ROUTE_TABLE")" ] &&
            ip -4 rule add pref "$old_pref" fwmark "$SBSHELL_PROXY_FWMARK" lookup "$SBSHELL_ROUTE_TABLE" 2>/dev/null || true
    fi
    if [ "${prior_route_owned:-0}" -eq 1 ]; then
        route_default_exists "${OLD_INTERFACE:-$INTERFACE}" ||
            ip -4 route add local default dev "${OLD_INTERFACE:-$INTERFACE}" table "$SBSHELL_ROUTE_TABLE" 2>/dev/null || true
    fi
    if [ -s "$OLD_TABLE" ]; then
        nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box || true
        nft -f "$OLD_TABLE" 2>/dev/null || true
    elif [ "${TABLE_CREATED:-0}" -eq 1 ]; then
        # 首次安装（没有旧表可恢复）时失败：必须删掉本次建的表。否则删了 pending 之后，
        # 它就成了一张"非 Sbshell 管理"的无主表，configure/clean 都会永久拒绝（旧的坑）。
        nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box || true
    fi
    nft list table inet sing-box-tun >/dev/null 2>&1 && nft delete table inet sing-box-tun || true
    if [ -s "$OLD_TUN_TABLE" ]; then
        nft -f "$OLD_TUN_TABLE" 2>/dev/null || true
        [ ! -s "$OLD_TUN_STATE" ] || install -o root -g root -m 0600 "$OLD_TUN_STATE" "$TUN_STATE_FILE"
    else
        rm -f "$TUN_STATE_FILE" "$TUN_STATE_FILE.pending"
    fi
    # 回到（或确认回不到）一致状态后，本次的 pending 主张一并作废。
    rm -f "$STATE_PENDING"
}

# 与 configure_tun.sh 对齐：任何**未预期**的失败（不是下面那几处显式 `rollback; exit 1`）
# 也必须回滚，否则会留下"表已拆掉、state 还声称拥有它"的半拆状态。rollback 定义在上面，
# 所以这条 trap 只能到这里才安装：更早的几步（拆 TUN 表）依赖显式调用。
trap 'rollback || true' ERR
trap 'rollback || true; exit 1' INT TERM

# table 100 里是否已有我们需要的 local default 路由（幂等判断与回滚恢复共用）。
route_default_exists() {
    ip -4 route show table "$SBSHELL_ROUTE_TABLE" | awk -v ifc="$1" '$0 == "local default dev " ifc || index($0, "local default dev " ifc " ") == 1 {found=1} END {exit !found}'
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

ACTUAL_RULE_PREF=$(rule_pref_for_mark "$SBSHELL_PROXY_FWMARK" "$SBSHELL_ROUTE_TABLE")
if [ -z "$ACTUAL_RULE_PREF" ]; then
    if ! ip -4 rule add pref "$SBSHELL_RULE_PREF" fwmark "$SBSHELL_PROXY_FWMARK" lookup "$SBSHELL_ROUTE_TABLE"; then rollback; exit 1; fi
    RULE_CREATED=1
    RULE_OWNED=1
    ACTUAL_RULE_PREF="$SBSHELL_RULE_PREF"
fi
if ! route_default_exists "$INTERFACE"; then
    if ! ip -4 route add local default dev "$INTERFACE" table "$SBSHELL_ROUTE_TABLE"; then rollback; exit 1; fi
    ROUTE_CREATED=1
    ROUTE_OWNED=1
fi

if [ "$prior_rule_created" -eq 1 ]; then RULE_CREATED=0; fi
if [ "$prior_route_created" -eq 1 ] && [ "$ROUTE_CREATED" -eq 0 ]; then ROUTE_CREATED=0; fi

# 两阶段提交 · 第 1 阶段：**建表之前**先按最终 state 的内容发布 pending。
# 崩溃点若落在「nft -f 成功之后、state 落盘之前」，磁盘上会只剩这张表和 pending；
# configure/clean 用 fw_owned 认它为 Sbshell 所有，从而能自愈回收，而不是永久拒绝。
# 同目录临时文件 + rename：掉电或被中断时不会留下**半写**的 pending。
STATE_TMP=$(mktemp /etc/sing-box/.tproxy.state.XXXXXX) || { rollback; exit 1; }
cat > "$STATE_TMP" <<EOF
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
chown root:root "$STATE_TMP"; chmod 0600 "$STATE_TMP"
PENDING_TMP=$(mktemp /etc/sing-box/.tproxy.state.pending.XXXXXX) || { rollback; exit 1; }
cp "$STATE_TMP" "$PENDING_TMP" || { rollback; exit 1; }
chown root:root "$PENDING_TMP"; chmod 0600 "$PENDING_TMP"
mv -f "$PENDING_TMP" "$STATE_PENDING"
PENDING_TMP=''

if nft list table inet sing-box >/dev/null 2>&1; then
    echo '检测到非 Sbshell 管理的 inet sing-box 表，拒绝覆盖。' >&2
    rollback
    exit 1
fi
if ! nft -f "$TMP"; then
    rollback
    exit 1
fi
TABLE_CREATED=1

# 两阶段提交 · 第 2 阶段：state 先原子落盘（同目录临时文件 + rename），再删除 pending。
# 顺序不能反：先删 pending 再写 state，中间的崩溃就又回到了"无主表"。
chown root:root "$STATE_TMP"; chmod 0600 "$STATE_TMP"
mv -f "$STATE_TMP" "$STATE_FILE"
STATE_TMP=''
rm -f "$STATE_PENDING"
rm -f "$TUN_STATE_FILE" "$TUN_NFT_FILE"
echo 'TProxy 模式防火墙规则已安全应用。'
