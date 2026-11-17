#!/bin/bash
set -Eeuo pipefail

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

# 同 configure_tproxy.sh：按 "dev" 关键字取网卡，避免 dev-only 默认路由取到 "link"。
INTERFACE=$(ip route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
# 同 configure_tproxy.sh：pipefail 下 sed 的失败会中止脚本（mode.conf 缺失时到不了下面的 guard）。
MODE=$( { sed -n 's/^MODE=//p' /etc/sing-box/mode.conf 2>/dev/null || true; } | head -n1)
[ "$MODE" = TUN ] || exit 0
[ -n "$INTERFACE" ] || { echo '无法确定默认网卡。' >&2; exit 1; }
command -v nft >/dev/null 2>&1 || { echo '缺少 nft。' >&2; exit 1; }

NFT_DIR=/etc/sing-box/tun
NFT_FILE="$NFT_DIR/nftables.conf"
TUN_STATE_FILE=/etc/sing-box/tun.state
# 两阶段提交的 pending 标记：建表**之前**落盘，state 落盘之后删除（崩溃后可据此回收表）。
TUN_STATE_PENDING="$TUN_STATE_FILE.pending"
TPROXY_STATE_FILE=/etc/sing-box/tproxy.state
PENDING_TMP=''
TMP=$(mktemp /tmp/sbshell-tun.XXXXXX)
OLD_TUN_TABLE=$(mktemp /tmp/sbshell-tun-table.XXXXXX)
OLD_TUN_STATE=$(mktemp /tmp/sbshell-tun-state.XXXXXX)
OLD_TPROXY_TABLE=$(mktemp /tmp/sbshell-tproxy-table.XXXXXX)
OLD_TPROXY_STATE=$(mktemp /tmp/sbshell-tproxy-state.XXXXXX)
OLD_RULE=$(mktemp /tmp/sbshell-tun-rule.XXXXXX)
OLD_ROUTE=$(mktemp /tmp/sbshell-tun-route.XXXXXX)
trap 'rm -f "$TMP" "$OLD_TUN_TABLE" "$OLD_TUN_STATE" "$OLD_TPROXY_TABLE" "$OLD_TPROXY_STATE" "$OLD_RULE" "$OLD_ROUTE"; [ -z "$PENDING_TMP" ] || rm -f "$PENDING_TMP"' EXIT
mkdir -p "$NFT_DIR" /etc/sing-box
# B2：nft/ip 变更前加锁，避免并发切换/清理互相拆表；没有 flock 时静默跳过（保持旧行为）。
LOCK_FILE=/var/lock/sbshell-firewall.lock
mkdir -p /var/lock
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -w 20 9 || { echo '另一个防火墙操作正在进行，请稍后重试。' >&2; exit 1; }
fi

# 先构建并校验规则，再做任何破坏性操作（旧版本先拆后验：`nft -c` 在拆除之后、
# 且在唯一的恢复块之外，失败即留下半拆除状态且无恢复）。
cat > "$TMP" <<'EOF'
table inet sing-box-tun {
    chain forward { type filter hook forward priority 0; policy accept; }
}
EOF
nft -c -f "$TMP"

SNAPSHOTTED=0
APPLIED=0
TUN_CREATED=0
restore_prev() {
    # 尚未开始改动（例如校验失败）时无需恢复；已成功应用时不回退。
    [ "$APPLIED" -eq 0 ] || return 0
    # 两阶段提交：进入任何回滚分支都代表本次的 pending 主张作废 ——
    # 表要么被旧表恢复，要么被下面的 TUN_CREATED 分支删掉（不存在"两边都没有"的情况）。
    rm -f "$TUN_STATE_PENDING"
    if [ "$SNAPSHOTTED" -eq 1 ]; then
        nft list table inet sing-box-tun >/dev/null 2>&1 && nft delete table inet sing-box-tun || true
        if [ -s "$OLD_TUN_TABLE" ]; then
            nft -f "$OLD_TUN_TABLE" 2>/dev/null || true
            [ ! -s "$OLD_TUN_STATE" ] || install -o root -g root -m 0600 "$OLD_TUN_STATE" "$TUN_STATE_FILE"
        else
            rm -f "$TUN_STATE_FILE"
        fi
    elif [ "$TUN_CREATED" -eq 1 ]; then
        # B1：首次安装没有快照可恢复，必须删掉刚建的表（并清掉 state），
        # 否则它就成了"非 Sbshell 管理"的无主表，之后 configure_tproxy/clean_nft 全部拒绝。
        nft list table inet sing-box-tun >/dev/null 2>&1 && nft delete table inet sing-box-tun || true
        rm -f "$TUN_STATE_FILE"
    else
        # 校验阶段就失败：还没拆/建任何东西，直接返回（否则会误删已有的 tproxy.state）。
        return 0
    fi
    [ ! -s "$OLD_TPROXY_TABLE" ] || nft -f "$OLD_TPROXY_TABLE" 2>/dev/null || true
    # 策略规则/路由快照恢复（iproute2 用制表符分隔 pref 与规则体）。
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        pref=${line%%:*}
        spec=${line#*:}
        spec=${spec#"${spec%%[![:space:]]*}"}
        case "$pref" in ''|*[!0-9]*) continue ;; esac
        [ -n "$spec" ] || continue
        ip -4 rule show | grep -Fq "$spec" || ip -4 rule add pref "$pref" $spec 2>/dev/null || true
    done < "$OLD_RULE"
    while IFS= read -r route; do
        [ -n "$route" ] || continue
        ip -4 route show table "$SBSHELL_ROUTE_TABLE" | grep -Fqx "$route" || ip -4 route add table "$SBSHELL_ROUTE_TABLE" $route 2>/dev/null || true
    done < "$OLD_ROUTE"
    if [ -s "$OLD_TPROXY_STATE" ]; then install -o root -g root -m 0600 "$OLD_TPROXY_STATE" "$TPROXY_STATE_FILE"; else rm -f "$TPROXY_STATE_FILE" "$TPROXY_STATE_FILE.pending"; fi
    return 0
}
trap 'restore_prev || true' ERR
trap 'restore_prev || true; exit 1' INT TERM

ip -4 rule show > "$OLD_RULE" 2>/dev/null || true
ip -4 route show table "$SBSHELL_ROUTE_TABLE" > "$OLD_ROUTE" 2>/dev/null || true

if nft list table inet sing-box-tun > "$OLD_TUN_TABLE" 2>/dev/null; then
    if fw_owned "$TUN_STATE_FILE"; then
        # 只有 pending、没有 state（上次在建表与落盘之间崩溃）时，字段从 pending 里取。
        OLD_TUN_STATE_SRC="$TUN_STATE_FILE"
        [ -f "$OLD_TUN_STATE_SRC" ] || OLD_TUN_STATE_SRC="$TUN_STATE_PENDING"
        cp "$OLD_TUN_STATE_SRC" "$OLD_TUN_STATE"
        SNAPSHOTTED=1
        nft delete table inet sing-box-tun
    else
        echo '检测到非 Sbshell 管理的 inet sing-box-tun 表，拒绝覆盖。' >&2
        exit 1
    fi
else
    : > "$OLD_TUN_TABLE"
    : > "$OLD_TUN_STATE"
fi

# 以 tproxy.state 的所有权为准，而不是“表是否存在”（表可能被外部工具删除，
# 而 ip rule/route 仍在，此时也必须按 state 清理）。state 缺失时 pending 同样算数。
TPROXY_OWNED=0
if fw_owned "$TPROXY_STATE_FILE"; then
    TPROXY_OWNED=1
    TPROXY_STATE_SRC="$TPROXY_STATE_FILE"
    [ -f "$TPROXY_STATE_SRC" ] || TPROXY_STATE_SRC="$TPROXY_STATE_FILE.pending"
    cp "$TPROXY_STATE_SRC" "$OLD_TPROXY_STATE"
fi
if nft list table inet sing-box > "$OLD_TPROXY_TABLE" 2>/dev/null; then
    if [ "$TPROXY_OWNED" -eq 1 ]; then
        SNAPSHOTTED=1
        nft delete table inet sing-box
    else
        echo '检测到非 Sbshell 管理的 inet sing-box 表，拒绝覆盖。' >&2
        [ ! -s "$OLD_TUN_TABLE" ] || nft -f "$OLD_TUN_TABLE" 2>/dev/null || true
        exit 1
    fi
else
    : > "$OLD_TPROXY_TABLE"
fi
[ "$TPROXY_OWNED" -eq 1 ] || : > "$OLD_TPROXY_STATE"

if [ -s "$OLD_TPROXY_STATE" ]; then
    old_pref=$(sed -n 's/^RULE_PREF=//p' "$OLD_TPROXY_STATE" | head -n1)
    old_interface=$(sed -n 's/^INTERFACE=//p' "$OLD_TPROXY_STATE" | head -n1)
    [ -n "$old_interface" ] || old_interface="$INTERFACE"
    rule_owned=0
    route_owned=0
    grep -q '^RULE_OWNED=1$' "$OLD_TPROXY_STATE" && rule_owned=1
    grep -q '^ROUTE_OWNED=1$' "$OLD_TPROXY_STATE" && route_owned=1
    [ "$rule_owned" -eq 1 ] || { grep -q '^RULE_CREATED=1$' "$OLD_TPROXY_STATE" && rule_owned=1; }
    [ "$route_owned" -eq 1 ] || { grep -q '^ROUTE_CREATED=1$' "$OLD_TPROXY_STATE" && route_owned=1; }
    if [ "$rule_owned" -eq 1 ] && [ -n "$old_pref" ]; then
        ip -4 rule del pref "$old_pref" fwmark "$SBSHELL_PROXY_FWMARK" lookup "$SBSHELL_ROUTE_TABLE" 2>/dev/null || true
    fi
    if [ "$route_owned" -eq 1 ]; then
        ip -4 route del local default dev "$old_interface" table "$SBSHELL_ROUTE_TABLE" 2>/dev/null || true
    fi
    rm -f "$TPROXY_STATE_FILE" "$TPROXY_STATE_FILE.pending"
fi

# 两阶段提交 · 第 1 阶段：**建表之前**先按最终 state 的内容发布 pending（同目录临时文件 +
# rename，绝不写半截）。崩溃点若落在「nft -f 成功、state 未落盘」之间，configure/clean
# 靠 fw_owned 认它为 Sbshell 所有，能自愈回收，而不是当成外来表永久拒绝。
PENDING_TMP=$(mktemp /etc/sing-box/.tun.state.pending.XXXXXX) || { restore_prev; exit 1; }
cat > "$PENDING_TMP" <<EOF
OWNER=sbshell
MODE=TUN
TUN_TABLE_CREATED=1
INTERFACE=$INTERFACE
EOF
chown root:root "$PENDING_TMP"
chmod 0600 "$PENDING_TMP"
mv -f "$PENDING_TMP" "$TUN_STATE_PENDING"
PENDING_TMP=''

if ! nft -f "$TMP"; then
    restore_prev
    exit 1
fi
# B1：表已经建出来，后面的 install/mktemp/mv 任一步失败都必须把这张表删掉。
TUN_CREATED=1

install -o root -g root -m 0644 "$TMP" "$NFT_FILE"
# 同目录临时文件 + rename，避免掉电/中断留下半写的 state（见 configure_tproxy.sh 的同类处理）。
TUN_STATE_TMP=$(mktemp /etc/sing-box/.tun.state.XXXXXX) || { restore_prev; exit 1; }
cat > "$TUN_STATE_TMP" <<EOF
OWNER=sbshell
MODE=TUN
TUN_TABLE_CREATED=1
INTERFACE=$INTERFACE
EOF
chown root:root "$TUN_STATE_TMP"
chmod 0600 "$TUN_STATE_TMP"
mv -f "$TUN_STATE_TMP" "$TUN_STATE_FILE"
APPLIED=1
# 两阶段提交 · 第 2 阶段完成：state 已原子落盘，pending 的使命结束（顺序不能反）。
rm -f "$TUN_STATE_PENDING"
echo 'TUN 模式防火墙规则已安全应用。'
