#!/bin/bash
set -Eeuo pipefail

DEBIAN_MAIN_SCRIPT_URL=https://raw.githubusercontent.com/meiao123/sbshell/main/debian/menu.sh
OPENWRT_MAIN_SCRIPT_URL=https://raw.githubusercontent.com/meiao123/sbshell/main/openwrt/menu.sh
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

echo -e "${GREEN}主脚本下载并校验完成。${NC}"
echo -e "${YELLOW}注意：脚本会修改系统网络、防火墙和 sing-box 配置，请确认已做好备份。${NC}"
exec bash "$SCRIPT_DIR/menu.sh" "$@"
