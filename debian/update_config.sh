#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CONFIG_URL_FILE="${CONFIG_DIR}/config.url"
DEFAULT_CONFIG_URL="https://raw.githubusercontent.com/qljsyph/sbshell/main/config_template/server/config.json"

if [ ! -d "$CONFIG_DIR" ]; then
    echo -e "${RED}sing-box 未安装或配置文件目录不存在，请先执行安装。${NC}" >&2
    exit 1
fi

config_url=""
if [ -s "$CONFIG_URL_FILE" ]; then
    config_url=$(<"$CONFIG_URL_FILE")
    echo -e "${YELLOW}当前配置链接为: ${NC}$config_url"
    read -rp "是否更换配置链接? (y/N): " change_url
    if [[ "$change_url" =~ ^[Yy]$ ]]; then
        read -rp "请输入新的配置链接: " config_url
    fi
else
    read -rp "首次使用,请输入配置链接 [回车使用默认]: " config_url
    [ -z "$config_url" ] && config_url="$DEFAULT_CONFIG_URL"
fi

if [[ ! "$config_url" =~ ^https:// ]]; then
    echo -e "${RED}配置链接必须使用 HTTPS。${NC}" >&2
    exit 1
fi

tmp_config=$(mktemp "${CONFIG_DIR}/.config.json.XXXXXX")
backup_config=$(mktemp "${CONFIG_DIR}/.config.json.backup.XXXXXX")
cleanup() { rm -f "$tmp_config" "$backup_config"; }
trap cleanup EXIT

if [ -f "$CONFIG_FILE" ]; then
    cp -p -- "$CONFIG_FILE" "$backup_config"
fi

echo -e "${CYAN}正在从以下链接下载配置文件: ${NC}$config_url"
if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$config_url" -o "$tmp_config"; then
    echo -e "${RED}配置文件下载失败，保留现有配置。${NC}" >&2
    exit 1
fi

if [ ! -s "$tmp_config" ]; then
    echo -e "${RED}下载的配置文件为空，保留现有配置。${NC}" >&2
    exit 1
fi

if ! sing-box check -c "$tmp_config"; then
    echo -e "${RED}sing-box 配置校验失败，保留现有配置。${NC}" >&2
    exit 1
fi

install -o root -g root -m 0644 "$tmp_config" "$CONFIG_FILE"
printf '%s\n' "$config_url" > "$CONFIG_URL_FILE"
chmod 0644 "$CONFIG_URL_FILE"

if ! systemctl restart sing-box; then
    echo -e "${RED}服务重启失败，正在恢复上一份配置。${NC}" >&2
    if [ -s "$backup_config" ]; then
        install -o root -g root -m 0644 "$backup_config" "$CONFIG_FILE"
        systemctl restart sing-box || true
    fi
    exit 1
fi

echo -e "${GREEN}配置更新成功，服务已正常重启。${NC}"
