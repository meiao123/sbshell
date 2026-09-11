#!/bin/bash
set -Eeuo pipefail

DEBIAN_MAIN_SCRIPT_URL="https://raw.githubusercontent.com/meiao123/sbshell/main/debian/menu.sh"
OPENWRT_MAIN_SCRIPT_URL="https://raw.githubusercontent.com/meiao123/sbshell/main/openwrt/menu.sh"
SCRIPT_DIR="/etc/sing-box/scripts"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [[ "$(uname -s)" != "Linux" ]]; then
    echo -e "${RED}当前系统不支持运行此脚本。${NC}" >&2
    exit 1
fi

is_openwrt=false
if grep -qi 'openwrt' /etc/os-release; then
    is_openwrt=true
    echo -e "${GREEN}系统为 OpenWrt，支持运行此脚本。${NC}"
elif grep -Eqi 'debian|ubuntu|armbian' /etc/os-release; then
    echo -e "${GREEN}系统为 Debian/Ubuntu/Armbian，支持运行此脚本。${NC}"
else
    echo -e "${RED}当前系统不是 Debian/Ubuntu/Armbian/OpenWrt，不支持运行此脚本。${NC}" >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    if $is_openwrt; then
        opkg update
        opkg install curl
    else
        apt-get update
        apt-get install -y curl
    fi
fi
command -v curl >/dev/null 2>&1 || { echo -e "${RED}curl 安装失败。${NC}" >&2; exit 1; }

if ! $is_openwrt; then
    for dep in wget nftables; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            apt-get update
            apt-get install -y "$dep"
        fi
    done
else
    command -v nft >/dev/null 2>&1 || { opkg update; opkg install nftables; }
fi

# 管理脚本必须由 root 持有，避免普通用户篡改后被管理员执行而造成提权。
if $is_openwrt; then
    mkdir -p "$SCRIPT_DIR"
else
    install -d -o root -g root -m 0755 "$SCRIPT_DIR"
fi

if $is_openwrt; then
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$OPENWRT_MAIN_SCRIPT_URL" -o "$tmp"
else
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$DEBIAN_MAIN_SCRIPT_URL" -o "$tmp"
fi

bash -n "$tmp"
if $is_openwrt; then
    install -o root -g root -m 0755 "$tmp" "$SCRIPT_DIR/menu.sh"
else
    install -o root -g root -m 0755 "$tmp" "$SCRIPT_DIR/menu.sh"
fi

rm -f "$tmp"
trap - EXIT

echo -e "${GREEN}主脚本下载并校验完成。${NC}"
echo -e "${YELLOW}注意：脚本会修改系统网络、防火墙和 sing-box 配置，请确认已做好备份。${NC}"
exec bash "$SCRIPT_DIR/menu.sh" "$@"
