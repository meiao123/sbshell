#!/bin/bash
set -Eeuo pipefail

DEBIAN_MAIN_SCRIPT_URL="https://raw.githubusercontent.com/meiao123/sbshell/main/debian/menu.sh"
OPENWRT_MAIN_SCRIPT_URL="https://raw.githubusercontent.com/meiao123/sbshell/main/openwrt/menu.sh"
SCRIPT_DIR="/etc/sing-box/scripts"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

if [[ "$(uname -s)" != "Linux" ]]; then echo -e "${RED}当前系统不支持运行此脚本。${NC}" >&2; exit 1; fi

is_openwrt=false
if grep -qi 'openwrt' /etc/os-release; then
    is_openwrt=true
    echo -e "${GREEN}系统为 OpenWrt，支持运行此脚本。${NC}"
elif grep -Eqi 'debian|ubuntu|armbian' /etc/os-release; then
    echo -e "${GREEN}系统为 Debian/Ubuntu/Armbian，支持运行此脚本。${NC}"
else
    echo -e "${RED}当前系统不是 Debian/Ubuntu/Armbian/OpenWrt，不支持运行此脚本。${NC}" >&2; exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    if $is_openwrt; then opkg update && opkg install curl; else apt-get update && apt-get install -y curl; fi
fi
command -v curl >/dev/null 2>&1 || { echo -e "${RED}curl 安装失败。${NC}" >&2; exit 1; }

if ! $is_openwrt; then
    for dep in wget nftables; do
        if ! command -v "$dep" >/dev/null 2>&1; then apt-get update && apt-get install -y "$dep"; fi
    done
else
    command -v nft >/dev/null 2>&1 || { opkg update && opkg install nftables; }
fi

install -d -o root -g root -m 0755 "$SCRIPT_DIR"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if $is_openwrt; then
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$OPENWRT_MAIN_SCRIPT_URL" -o "$tmp"
else
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$DEBIAN_MAIN_SCRIPT_URL" -o "$tmp"
fi
bash -n "$tmp"
install -o root -g root -m 0755 "$tmp" "$SCRIPT_DIR/menu.sh"
rm -f "$tmp"; trap - EXIT

echo -e "${GREEN}主脚本下载并校验完成。${NC}"
echo -e "${YELLOW}注意：脚本会修改系统网络、防火墙和 sing-box 配置，请确认已做好备份。${NC}"

# 初始化阶段需要写入 root-owned 脚本目录，因此以 root 运行菜单。
if [ "$(id -u)" -eq 0 ]; then
    exec bash "$SCRIPT_DIR/menu.sh" "$@"
elif command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$SCRIPT_DIR/menu.sh" "$@"
else
    echo -e "${RED}需要 root 权限运行初始化菜单。${NC}" >&2
    exit 1
fi
