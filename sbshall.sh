#!/bin/bash
set -Eeuo pipefail

# --- busybox 兼容：ImmortalWrt/OpenWrt 的 busybox 常常没有 install applet ---
# 真机实测（ImmortalWrt）：一键引导在第一步就中止
#   /dev/fd/64: line 57: install: command not found
# 本仓库大量依赖 GNU install 的 -d/-o/-g/-m，busybox 没有等价命令，因此这里在缺失时
# 定义一个只覆盖本仓库用法的兜底实现；只要系统有真正的 install，这段完全不生效。
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
            [ -n "$m" ] && chmod "$m" "$@" 2>/dev/null
        else
            # 本仓库只用 `install [-m M] [-o U] [-g G] SRC DST`
            [ $# -eq 2 ] || return 1
            cp -f "$1" "$2" || return 1
            [ -n "$m" ] && chmod "$m" "$2" 2>/dev/null
            set -- "$2"
        fi
        [ -n "$o" ] && chown "$o${g:+:$g}" "$@" 2>/dev/null
        return 0
    }
fi

# 内置的发布提交（兜底）：提交无法包含自身 SHA，所以任何写死的引用都必然指向"上一版"，
# 只信它会出现「装好加固版后点一次更新就回退到修复前版本」的一跳回退（见 docs/security-hardening.md）。
# 因此下面按 main 上的 `RELEASE` 声明解析真正的发布提交，只有解析失败才用这个常量。
RELEASE_REF=91865d43c91b5d22141d412c27d3c54624c4be95
REPO_RAW="https://raw.githubusercontent.com/meiao123/sbshell"
RELEASE_DECL_URL="$REPO_RAW/refs/heads/main/RELEASE"
resolve_release_ref() {
    local declared=''
    declared=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 20 "$RELEASE_DECL_URL" 2>/dev/null | tr -d '\r\n') || declared=''
    case "$declared" in
        *[!0-9a-f]*) ;;
        *) if [ "${#declared}" -eq 40 ]; then RELEASE_REF=$declared; fi ;;
    esac
    return 0
}
SCRIPT_DIR=/etc/sing-box/scripts
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

[ "$(uname -s)" = Linux ] || { echo -e "${RED}当前系统不支持运行此脚本。${NC}" >&2; exit 1; }
[ -r /etc/os-release ] || { echo -e "${RED}无法识别操作系统。${NC}" >&2; exit 1; }

is_openwrt=false
if grep -qi openwrt /etc/os-release; then
    is_openwrt=true
    echo -e "${GREEN}系统为 OpenWrt。${NC}"
elif grep -Eqi 'debian|ubuntu|armbian' /etc/os-release; then
    echo -e "${GREEN}系统为 Debian/Ubuntu/Armbian。${NC}"
else
    echo -e "${RED}当前系统不是受支持的 Debian/Ubuntu/Armbian/OpenWrt。${NC}" >&2
    exit 1
fi

install_package() {
    local package="$1"
    if $is_openwrt; then opkg update && opkg install "$package"; else apt-get update && apt-get install -y "$package"; fi
}
ensure_command() {
    local command="$1" package="$2"
    command -v "$command" >/dev/null 2>&1 || install_package "$package"
}
ensure_command curl curl
ensure_command bash bash
ensure_command nft nftables
command -v curl >/dev/null 2>&1 || { echo -e "${RED}curl 安装失败。${NC}" >&2; exit 1; }
command -v bash >/dev/null 2>&1 || { echo -e "${RED}bash 安装失败。${NC}" >&2; exit 1; }
command -v nft >/dev/null 2>&1 || { echo -e "${RED}nft 安装失败。${NC}" >&2; exit 1; }

# curl 已就绪，现在解析发布提交（解析失败则保留内置的已加固提交）。
resolve_release_ref
DEBIAN_MAIN_SCRIPT_URL="$REPO_RAW/$RELEASE_REF/debian/menu.sh"
OPENWRT_MAIN_SCRIPT_URL="$REPO_RAW/$RELEASE_REF/openwrt/menu.sh"

install -d -o root -g root -m 0755 "$SCRIPT_DIR"
tmp=$(mktemp /tmp/sbshell-menu.XXXXXX)
trap 'rm -f "$tmp"' EXIT
if $is_openwrt; then
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$OPENWRT_MAIN_SCRIPT_URL" -o "$tmp"
else
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$DEBIAN_MAIN_SCRIPT_URL" -o "$tmp"
fi
[ -s "$tmp" ] || { echo -e "${RED}主脚本下载为空。${NC}" >&2; exit 1; }
bash -n "$tmp"
install -o root -g root -m 0755 "$tmp" "$SCRIPT_DIR/menu.sh"

echo -e "${GREEN}主脚本下载并校验完成（审核发布引用: $RELEASE_REF）。${NC}"
echo -e "${YELLOW}注意：脚本会修改系统网络、防火墙和 sing-box 配置，请确认已做好备份。${NC}"
# exec 不会触发 EXIT trap，这里显式清理临时文件
rm -f "$tmp"
trap - EXIT
exec bash "$SCRIPT_DIR/menu.sh" "$@"
