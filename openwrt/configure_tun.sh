#!/bin/bash
set -Eeuo pipefail



# --- busybox 兼容：ImmortalWrt/OpenWrt 的 busybox 常常没有 install applet ---
# 真机实测（ImmortalWrt）：一键引导在第一步就中止
#   /dev/fd/64: line 57: install: command not found
# 本仓库大量依赖 GNU install 的 -d/-o/-g/-m，busybox 没有等价命令，因此这里在缺失时
# 定义一个只覆盖本仓库用法的兜底实现；只要系统有真正的 install，这段完全不生效。
#
# 与调用方 `set -Eeuo pipefail` 的关系（踩过坑）：
#   * chmod 失败必须让本次 install **返回非 0**（fail-closed：凭据文件绝不能悄悄留在 0644），
#     并且要 `return 1` 而不是让 errexit 在函数内部直接终止整个脚本——否则调用方的
#     `if ! install …; then restore; fi` 回滚逻辑根本没机会执行；
#   * chown 失败不影响返回码（所有权不构成安全边界，且 vfat/extroot 等文件系统上会失败）。
# 写法上一律用 `[ -z "$x" ] || { cmd … || …; }`：判空为真时整行返回 0，
# 且 `cmd` 处于 `||` 列表首位时不受 errexit 影响，失败能被显式处理。
if ! command -v install >/dev/null 2>&1; then
    install() {
        local d=0 m='' o='' g=''
        while [ $# -gt 0 ]; do
            case "$1" in
                -d) d=1; shift ;;
                -m) m="$2"; shift 2 ;;
                -o) o="$2"; shift 2 ;;
                -g) g="$2"; shift 2 ;;
                -*) shift ;;
                *) break ;;
            esac
        done
        if [ "$d" -eq 1 ]; then
            mkdir -p "$@" || return 1
            [ -z "$m" ] || { chmod "$m" "$@" 2>/dev/null || return 1; }
        else
            # 本仓库只用 `install [-m M] [-o U] [-g G] SRC DST`
            [ $# -eq 2 ] || return 1
            # 先 rm 再写，避免覆盖正在运行脚本的 inode（写正在执行的脚本会 ETXTBSY 而失败）。
            rm -f "$2" 2>/dev/null || true
            cp -f "$1" "$2" || return 1
            [ -z "$m" ] || { chmod "$m" "$2" 2>/dev/null || return 1; }
            set -- "$2"
        fi
        [ -z "$o" ] || { chown "$o${g:+:$g}" "$@" 2>/dev/null || true; }
        return 0
    }
fi

PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100
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
restore_prev() {
    # 尚未开始改动（例如校验失败）时无需恢复；已成功应用时不回退。
    [ "$SNAPSHOTTED" -eq 1 ] || return 0
    [ "$APPLIED" -eq 0 ] || return 0
    nft list table inet sing-box-tun >/dev/null 2>&1 && nft delete table inet sing-box-tun || true
    if [ -s "$OLD_TUN_TABLE" ]; then
        nft -f "$OLD_TUN_TABLE" 2>/dev/null || true
        [ ! -s "$OLD_TUN_STATE" ] || install -o root -g root -m 0600 "$OLD_TUN_STATE" "$TUN_STATE_FILE"
    else
        rm -f "$TUN_STATE_FILE"
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
        ip -4 route show table "$PROXY_ROUTE_TABLE" | grep -Fqx "$route" || ip -4 route add table "$PROXY_ROUTE_TABLE" $route 2>/dev/null || true
    done < "$OLD_ROUTE"
    if [ -s "$OLD_TPROXY_STATE" ]; then install -o root -g root -m 0600 "$OLD_TPROXY_STATE" "$TPROXY_STATE_FILE"; else rm -f "$TPROXY_STATE_FILE"; fi
    return 0
}
trap 'restore_prev || true' ERR
trap 'restore_prev || true; exit 1' INT TERM

ip -4 rule show > "$OLD_RULE" 2>/dev/null || true
ip -4 route show table "$PROXY_ROUTE_TABLE" > "$OLD_ROUTE" 2>/dev/null || true

if nft list table inet sing-box-tun > "$OLD_TUN_TABLE" 2>/dev/null; then
    if [ -f "$TUN_STATE_FILE" ] && grep -q '^OWNER=sbshell$' "$TUN_STATE_FILE"; then
        cp "$TUN_STATE_FILE" "$OLD_TUN_STATE"
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
# 而 ip rule/route 仍在，此时也必须按 state 清理）。
TPROXY_OWNED=0
if [ -f "$TPROXY_STATE_FILE" ] && grep -q '^OWNER=sbshell$' "$TPROXY_STATE_FILE"; then
    TPROXY_OWNED=1
    cp "$TPROXY_STATE_FILE" "$OLD_TPROXY_STATE"
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
    old_pref=$(sed -n 's/^RULE_PREF=//p' "$TPROXY_STATE_FILE" | head -n1)
    old_interface=$(sed -n 's/^INTERFACE=//p' "$TPROXY_STATE_FILE" | head -n1)
    [ -n "$old_interface" ] || old_interface="$INTERFACE"
    rule_owned=0
    route_owned=0
    grep -q '^RULE_OWNED=1$' "$TPROXY_STATE_FILE" && rule_owned=1
    grep -q '^ROUTE_OWNED=1$' "$TPROXY_STATE_FILE" && route_owned=1
    [ "$rule_owned" -eq 1 ] || { grep -q '^RULE_CREATED=1$' "$TPROXY_STATE_FILE" && rule_owned=1; }
    [ "$route_owned" -eq 1 ] || { grep -q '^ROUTE_CREATED=1$' "$TPROXY_STATE_FILE" && route_owned=1; }
    if [ "$rule_owned" -eq 1 ] && [ -n "$old_pref" ]; then
        ip -4 rule del pref "$old_pref" fwmark "$PROXY_FWMARK" lookup "$PROXY_ROUTE_TABLE" 2>/dev/null || true
    fi
    if [ "$route_owned" -eq 1 ]; then
        ip -4 route del local default dev "$old_interface" table "$PROXY_ROUTE_TABLE" 2>/dev/null || true
    fi
    rm -f "$TPROXY_STATE_FILE"
fi

if ! nft -f "$TMP"; then
    restore_prev
    exit 1
fi

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
echo 'TUN 模式防火墙规则已安全应用。'
