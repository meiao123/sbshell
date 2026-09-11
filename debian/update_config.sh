#!/bin/bash
set -Eeuo pipefail
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
CONFIG_DIR=/etc/sing-box
CONFIG_FILE="$CONFIG_DIR/config.json"
CONFIG_URL_FILE="$CONFIG_DIR/config.url"
DEFAULT_CONFIG_URL=https://raw.githubusercontent.com/qljsyph/sbshell/main/config_template/server/config.json

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
[ -d "$CONFIG_DIR" ] || { echo -e "${RED}sing-box 配置目录不存在，请先安装。${NC}" >&2; exit 1; }

config_url=''
if [ -s "$CONFIG_URL_FILE" ]; then
    config_url=$(<"$CONFIG_URL_FILE")
    echo -e "${YELLOW}当前配置链接已保存。${NC}"
    read -rp '是否更换配置链接? (y/N): ' change_url
    [[ "$change_url" =~ ^[Yy]$ ]] && read -rp '请输入新的配置链接: ' config_url
else
    read -rp '首次使用,请输入配置链接 [回车使用默认]: ' config_url
    config_url=${config_url:-$DEFAULT_CONFIG_URL}
fi
[[ "$config_url" =~ ^https://[^[:space:]]+$ ]] || { echo -e "${RED}配置链接必须使用 HTTPS。${NC}" >&2; exit 1; }

tmp_config=$(mktemp "$CONFIG_DIR/.config.json.XXXXXX")
backup_config=$(mktemp "$CONFIG_DIR/.config.json.backup.XXXXXX")
trap 'rm -f "$tmp_config" "$backup_config"' EXIT
[ ! -f "$CONFIG_FILE" ] || cp -p -- "$CONFIG_FILE" "$backup_config"

echo -e "${CYAN}正在下载配置文件...${NC}"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$config_url" -o "$tmp_config" || { echo -e "${RED}配置文件下载失败，保留现有配置。${NC}" >&2; exit 1; }
[ -s "$tmp_config" ] || { echo -e "${RED}下载的配置文件为空。${NC}" >&2; exit 1; }
sing-box check -c "$tmp_config" || { echo -e "${RED}配置校验失败，保留现有配置。${NC}" >&2; exit 1; }

install -o root -g root -m 0644 "$tmp_config" "$CONFIG_FILE"
printf '%s\n' "$config_url" > "$CONFIG_URL_FILE"
chown root:root "$CONFIG_URL_FILE"; chmod 0600 "$CONFIG_URL_FILE"
if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
    echo -e "${RED}服务重启失败，正在恢复上一份配置。${NC}" >&2
    [ ! -s "$backup_config" ] || install -o root -g root -m 0644 "$backup_config" "$CONFIG_FILE"
    systemctl restart sing-box || true
    exit 1
fi
echo -e "${GREEN}配置更新成功，服务已正常重启。${NC}"
