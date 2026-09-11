#!/bin/bash
set -Eeuo pipefail
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
CONFIG_DIR=/etc/sing-box
CONFIG_FILE="$CONFIG_DIR/config.json"
CONFIG_URL_FILE="$CONFIG_DIR/config.url"
SCRIPT_DIR="$CONFIG_DIR/scripts"
GENERATOR="$SCRIPT_DIR/gen_server_config.sh"
LOCK_FILE=/run/lock/sbshell-config.lock

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
[ -d "$CONFIG_DIR" ] || { echo -e "${RED}sing-box 配置目录不存在，请先安装。${NC}" >&2; exit 1; }
getent group sing-box >/dev/null 2>&1 || { echo -e "${RED}未找到 sing-box 服务组，请先安装 sing-box。${NC}" >&2; exit 1; }
install -d -o root -g root -m 0755 /run/lock
exec 9>"$LOCK_FILE"
flock -x 9

generate_locally() {
    [ -x "$GENERATOR" ] || [ -f "$GENERATOR" ] || {
        echo -e "${RED}未找到 $GENERATOR，请先执行菜单中的“更新脚本”。${NC}" >&2
        exit 1
    }
    exec bash "$GENERATOR"
}

config_url=''
if [ -s "$CONFIG_URL_FILE" ]; then
    config_url=$(<"$CONFIG_URL_FILE")
    echo '当前配置链接已保存。'
    read -rp '是否更换配置链接? 输入 y 更换，回车继续使用当前链接: ' change_url
    if [[ "$change_url" =~ ^[Yy]$ ]]; then
        read -rp '请输入新的配置链接（直接回车保留原链接）: ' new_url
        [ -z "$new_url" ] || config_url="$new_url"
    fi
else
    echo -e "${CYAN}首次配置服务端：直接回车将用本机随机凭据生成配置，也可输入配置链接。${NC}"
    read -rp '配置链接 [回车=本地生成]: ' config_url
fi
if [ -z "$config_url" ]; then
    generate_locally
fi
[[ "$config_url" =~ ^https://[^[:space:]]+$ ]] || { echo -e "${RED}配置链接必须使用 HTTPS。${NC}" >&2; exit 1; }

tmp_config=$(mktemp "$CONFIG_DIR/.config.json.XXXXXX")
backup_config=$(mktemp "$CONFIG_DIR/.config.json.backup.XXXXXX")
backup_url=$(mktemp "$CONFIG_DIR/.config.url.backup.XXXXXX")
trap 'rm -f "$tmp_config" "$backup_config" "$backup_url"' EXIT
chmod 0600 "$tmp_config" "$backup_config" "$backup_url"
config_existed=0
url_existed=0
if [ -f "$CONFIG_FILE" ]; then cp -p -- "$CONFIG_FILE" "$backup_config"; config_existed=1; fi
if [ -f "$CONFIG_URL_FILE" ]; then cp -p -- "$CONFIG_URL_FILE" "$backup_url"; url_existed=1; fi

echo -e "${CYAN}正在下载配置文件...${NC}"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$config_url" -o "$tmp_config" || { echo -e "${RED}配置文件下载失败，保留现有配置。${NC}" >&2; exit 1; }
[ -s "$tmp_config" ] || { echo -e "${RED}下载的配置文件为空。${NC}" >&2; exit 1; }
sing-box check -c "$tmp_config" || { echo -e "${RED}配置校验失败，保留现有配置。${NC}" >&2; exit 1; }

install -o root -g sing-box -m 0640 "$tmp_config" "$CONFIG_FILE"
printf '%s\n' "$config_url" > "$CONFIG_URL_FILE"
chown root:root "$CONFIG_URL_FILE"; chmod 0600 "$CONFIG_URL_FILE"
if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
    echo -e "${RED}服务重启失败，正在恢复上一份配置。${NC}" >&2
    if [ "$config_existed" -eq 1 ]; then install -o root -g sing-box -m 0640 "$backup_config" "$CONFIG_FILE"; else rm -f "$CONFIG_FILE"; fi
    if [ "$url_existed" -eq 1 ]; then install -o root -g root -m 0600 "$backup_url" "$CONFIG_URL_FILE"; else rm -f "$CONFIG_URL_FILE"; fi
    systemctl restart sing-box || true
    exit 1
fi
echo -e "${CYAN}配置更新成功，服务已正常重启。${NC}"
