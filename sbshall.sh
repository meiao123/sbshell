#!/bin/bash
set -Eeuo pipefail

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
            [ $# -eq 2 ] || return 1
            cp -f "$1" "$2" || return 1
            [ -z "$m" ] || { chmod "$m" "$2" 2>/dev/null || return 1; }
            set -- "$2"
        fi
        [ -z "$o" ] || { chown "$o${g:+:$g}" "$@" 2>/dev/null || true; }
        return 0
    }
fi

RELEASE_REF=7dfddbae21d224349bb4ba4ac2d81bd541d39b9d
REPO_RAW="https://raw.githubusercontent.com/meiao123/sbshell"
RELEASE_DECL_URL="$REPO_RAW/refs/heads/main/RELEASE"
github_api_download() {
    local path="$1" ref="$2" output="$3"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github.raw+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com/repos/meiao123/sbshell/contents/$path?ref=$ref" -o "$output" || return 1
    [ -s "$output" ] || { rm -f "$output"; return 1; }
}
download_repo_file() {
    local path="$1" ref="$2" output="$3"
    if curl --fail --silent --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 60 "$REPO_RAW/$ref/$path" -o "$output" 2>/dev/null && [ -s "$output" ]; then
        return 0
    fi
    rm -f "$output"
    github_api_download "$path" "$ref" "$output"
}
resolve_release_ref() {
    local tmp='/tmp/sbshell-release-ref' declared=''
    rm -f "$tmp"
    if download_repo_file 'RELEASE' 'main' "$tmp"; then
        declared=$(tr -d '\r\n' < "$tmp")
    fi
    rm -f "$tmp"
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

resolve_release_ref
DEBIAN_MAIN_SCRIPT_URL="$REPO_RAW/$RELEASE_REF/debian/menu.sh"
OPENWRT_MAIN_SCRIPT_URL="$REPO_RAW/$RELEASE_REF/openwrt/menu.sh"
install -d -o root -g root -m 0755 "$SCRIPT_DIR"
tmp=$(mktemp /tmp/sbshell-menu.XXXXXX)
trap 'rm -f "$tmp"' EXIT
if $is_openwrt; then
    download_repo_file "openwrt/menu.sh" "$RELEASE_REF" "$tmp"
else
    download_repo_file "debian/menu.sh" "$RELEASE_REF" "$tmp"
fi
[ -s "$tmp" ] || { echo -e "${RED}主脚本下载为空。${NC}" >&2; exit 1; }
bash -n "$tmp"
install -o root -g root -m 0755 "$tmp" "$SCRIPT_DIR/menu.sh"

echo -e "${GREEN}主脚本下载并校验完成（审核发布引用: $RELEASE_REF）。${NC}"
echo -e "${YELLOW}注意：脚本会修改系统网络、防火墙和 sing-box 配置，请确认已做好备份。${NC}"
rm -f "$tmp"
trap - EXIT
exec bash "$SCRIPT_DIR/menu.sh" "$@"
