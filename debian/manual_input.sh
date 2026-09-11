#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

MANUAL_FILE="/etc/sing-box/manual.conf"
DEFAULTS_FILE="/etc/sing-box/defaults.conf"
CONFIG_FILE="/etc/sing-box/config.json"
MODE_FILE="/etc/sing-box/mode.conf"

MODE=$(grep -oP '(?<=^MODE=).*' "$MODE_FILE" 2>/dev/null || true)

get_default() {
    local key="$1"
    grep -m1 "^${key}=" "$DEFAULTS_FILE" 2>/dev/null | cut -d'=' -f2- || true
}

valid_url() {
    [[ "$1" =~ ^https://[^[:space:]]+$ ]]
}

prompt_user_input() {
    read -rp "请输入后端地址(回车使用默认值可留空): " BACKEND_URL
    if [ -z "$BACKEND_URL" ]; then BACKEND_URL=$(get_default BACKEND_URL); fi

    read -rp "请输入订阅地址(回车使用默认值可留空): " SUBSCRIPTION_URL
    if [ -z "$SUBSCRIPTION_URL" ]; then SUBSCRIPTION_URL=$(get_default SUBSCRIPTION_URL); fi

    read -rp "请输入配置文件地址(回车使用默认值可留空): " TEMPLATE_URL
    if [ -z "$TEMPLATE_URL" ]; then
        case "$MODE" in
            TProxy) TEMPLATE_URL=$(get_default TPROXY_TEMPLATE_URL) ;;
            TUN) TEMPLATE_URL=$(get_default TUN_TEMPLATE_URL) ;;
            *) echo -e "${RED}未知的模式: $MODE${NC}"; return 1 ;;
        esac
    fi
}

while true; do
    prompt_user_input || exit 1
    echo -e "${CYAN}你输入的配置信息如下:${NC}"
    echo "后端地址: $BACKEND_URL"
    echo "订阅地址: $SUBSCRIPTION_URL"
    echo "配置文件地址: $TEMPLATE_URL"

    read -rp "确认输入的配置信息？(y/n): " confirm_choice
    if [[ "$confirm_choice" =~ ^[Yy]$ ]]; then
        if [ -n "$BACKEND_URL" ] && ! valid_url "$BACKEND_URL"; then echo -e "${RED}后端地址必须是 HTTPS URL。${NC}"; continue; fi
        if [ -n "$TEMPLATE_URL" ] && ! valid_url "$TEMPLATE_URL"; then echo -e "${RED}配置文件地址必须是 HTTPS URL。${NC}"; continue; fi
        if [ -n "$BACKEND_URL" ] && [ -z "$SUBSCRIPTION_URL" ]; then echo -e "${RED}使用后端地址时订阅地址不能为空。${NC}"; continue; fi

        install -d -o root -g root -m 0755 "$(dirname "$MANUAL_FILE")"
        tmp_manual=$(mktemp)
        trap 'rm -f "$tmp_manual"' EXIT
        printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TEMPLATE_URL" > "$tmp_manual"
        install -o root -g root -m 0600 "$tmp_manual" "$MANUAL_FILE"

        if [ -n "$BACKEND_URL" ] && [ -n "$SUBSCRIPTION_URL" ]; then
            FULL_URL="${BACKEND_URL%/}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"
        else
            FULL_URL="$TEMPLATE_URL"
        fi
        if ! valid_url "$FULL_URL"; then echo -e "${RED}生成的订阅 URL 无效。${NC}"; exit 1; fi

        echo "生成完整订阅链接: $FULL_URL"
        tmp_config=$(mktemp "$(dirname "$CONFIG_FILE")/.config.json.XXXXXX")
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$FULL_URL" -o "$tmp_config" || { rm -f "$tmp_config"; echo -e "${RED}配置文件下载失败。${NC}"; exit 1; }
        [ -s "$tmp_config" ] || { rm -f "$tmp_config"; echo -e "${RED}下载的配置为空。${NC}"; exit 1; }
        sing-box check -c "$tmp_config" || { rm -f "$tmp_config"; echo -e "${RED}配置文件验证失败，未覆盖现有配置。${NC}"; exit 1; }
        install -o root -g root -m 0644 "$tmp_config" "$CONFIG_FILE"
        rm -f "$tmp_config"
        echo "配置文件下载并验证成功。"
        break
    else
        echo -e "${RED}请重新输入配置信息。${NC}"
    fi
done
