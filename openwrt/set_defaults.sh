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
            cp -f "$1" "$2" || return 1
            [ -z "$m" ] || { chmod "$m" "$2" 2>/dev/null || return 1; }
            set -- "$2"
        fi
        [ -z "$o" ] || { chown "$o${g:+:$g}" "$@" 2>/dev/null || true; }
        return 0
    }
fi

[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
DEFAULTS_FILE=/etc/sing-box/defaults.conf
install -d -m 0755 /etc/sing-box
get_default() { awk -F= -v k="$1" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$DEFAULTS_FILE" 2>/dev/null || true; }
valid_url() { [[ "$1" =~ ^https?://[^[:space:]]+$ ]]; }

read -rp "请输入后端地址: " BACKEND_URL; BACKEND_URL=${BACKEND_URL:-$(get_default BACKEND_URL)}
read -rp "请输入订阅地址: " SUBSCRIPTION_URL; SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$(get_default SUBSCRIPTION_URL)}
read -rp "请输入TProxy配置文件地址: " TPROXY_TEMPLATE_URL; TPROXY_TEMPLATE_URL=${TPROXY_TEMPLATE_URL:-$(get_default TPROXY_TEMPLATE_URL)}
read -rp "请输入TUN配置文件地址: " TUN_TEMPLATE_URL; TUN_TEMPLATE_URL=${TUN_TEMPLATE_URL:-$(get_default TUN_TEMPLATE_URL)}

for value in "$BACKEND_URL" "$TPROXY_TEMPLATE_URL" "$TUN_TEMPLATE_URL"; do
    [ -z "$value" ] || valid_url "$value" || { echo '所有配置 URL 必须使用 HTTP 或 HTTPS。' >&2; exit 1; }
done
[ -n "$SUBSCRIPTION_URL" ] || { echo '订阅地址不能为空。' >&2; exit 1; }

tmp=$(mktemp /tmp/sbshell-defaults.XXXXXX)
trap 'rm -f "$tmp"' EXIT
printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTPROXY_TEMPLATE_URL=%s\nTUN_TEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TPROXY_TEMPLATE_URL" "$TUN_TEMPLATE_URL" > "$tmp"
install -m 0600 "$tmp" "$DEFAULTS_FILE"
echo '默认配置已更新。'
