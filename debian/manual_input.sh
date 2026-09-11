#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
MANUAL_FILE=/etc/sing-box/manual.conf
DEFAULTS_FILE=/etc/sing-box/defaults.conf
CONFIG_FILE=/etc/sing-box/config.json
MODE_FILE=/etc/sing-box/mode.conf
LOCK_FILE=/run/lock/sbshell-config.lock
TMP_FILES=()
cleanup() { local file; for file in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do rm -f "$file" 2>/dev/null || true; done; }
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
install -d -o root -g root -m 0755 /run/lock

get_default() { local key="$1"; grep -m1 "^${key}=" "$DEFAULTS_FILE" 2>/dev/null | cut -d'=' -f2- || true; }
valid_url() { [[ "$1" =~ ^https://[^[:space:]]+$ ]]; }
valid_subscription() {
    local value="$1"
    [ -z "$value" ] && return 0
    case "$value" in
        *[[:space:]]*|*'&file='*|*'#'*) return 1 ;;
    esac
    return 0
}

# 用 sed 解析 MODE，避免依赖 GNU grep 的 PCRE 扩展。
MODE=$(sed -n 's/^MODE=//p' "$MODE_FILE" 2>/dev/null | head -n1)
while true; do
    read -rp '请输入后端地址(回车使用默认值可留空): ' BACKEND_URL
    BACKEND_URL=${BACKEND_URL:-$(get_default BACKEND_URL)}
    read -rp '请输入订阅地址(回车使用默认值可留空): ' SUBSCRIPTION_URL
    SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$(get_default SUBSCRIPTION_URL)}
    read -rp '请输入配置文件地址(回车使用默认值可留空): ' TEMPLATE_URL
    if [ -z "$TEMPLATE_URL" ]; then
        case "$MODE" in TProxy) TEMPLATE_URL=$(get_default TPROXY_TEMPLATE_URL);; TUN) TEMPLATE_URL=$(get_default TUN_TEMPLATE_URL);; *) echo -e "${RED}未知的模式: $MODE${NC}"; exit 1;; esac
    fi
    echo -e "${CYAN}后端地址: $BACKEND_URL${NC}"
    echo -e "${CYAN}订阅地址: $SUBSCRIPTION_URL${NC}"
    echo -e "${CYAN}配置文件地址: $TEMPLATE_URL${NC}"
    read -rp '确认输入的配置信息？(y/n): ' confirm_choice
    [[ "$confirm_choice" =~ ^[Yy]$ ]] || continue
    [ -z "$BACKEND_URL" ] || valid_url "$BACKEND_URL" || { echo -e "${RED}后端地址必须是 HTTPS URL。${NC}"; continue; }
    [ -z "$TEMPLATE_URL" ] || valid_url "$TEMPLATE_URL" || { echo -e "${RED}配置文件地址必须是 HTTPS URL。${NC}"; continue; }
    valid_subscription "$SUBSCRIPTION_URL" || { echo -e "${RED}订阅地址包含非法字符。${NC}"; continue; }
    [ -z "$BACKEND_URL" ] || [ -n "$SUBSCRIPTION_URL" ] || { echo -e "${RED}使用后端地址时订阅地址不能为空。${NC}"; continue; }
    exec 9>"$LOCK_FILE"
    flock -x 9
    tmp_manual=$(mktemp "$MANUAL_FILE.XXXXXX")
    tmp_config=$(mktemp "$CONFIG_FILE.XXXXXX")
    backup_manual=$(mktemp "$MANUAL_FILE.backup.XXXXXX")
    backup_config=$(mktemp "$CONFIG_FILE.backup.XXXXXX")
    TMP_FILES+=("$tmp_manual" "$tmp_config" "$backup_manual" "$backup_config")
    manual_existed=0; config_existed=0
    printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TEMPLATE_URL" > "$tmp_manual"
    if [ -f "$MANUAL_FILE" ]; then install -o root -g root -m 0600 "$MANUAL_FILE" "$backup_manual"; manual_existed=1; fi
    if [ -n "$BACKEND_URL" ]; then FULL_URL="${BACKEND_URL%/}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"; else FULL_URL="$TEMPLATE_URL"; fi
    valid_url "$FULL_URL" || { echo -e "${RED}生成的订阅 URL 无效。${NC}" >&2; exit 1; }
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$FULL_URL" -o "$tmp_config" || { echo -e "${RED}配置下载失败。${NC}" >&2; exit 1; }
    [ -s "$tmp_config" ] || { echo -e "${RED}下载的配置为空。${NC}" >&2; exit 1; }
    sing-box check -c "$tmp_config" || { echo -e "${RED}配置验证失败。${NC}" >&2; exit 1; }
    if [ -f "$CONFIG_FILE" ]; then install -o root -g root -m 0600 "$CONFIG_FILE" "$backup_config"; config_existed=1; fi
    chown root:root "$tmp_manual" "$tmp_config"; chmod 0600 "$tmp_manual"; chmod 0644 "$tmp_config"
    mv -f "$tmp_manual" "$MANUAL_FILE"
    if ! mv -f "$tmp_config" "$CONFIG_FILE"; then
        if [ "$manual_existed" -eq 1 ]; then install -o root -g root -m 0600 "$backup_manual" "$MANUAL_FILE"; else rm -f "$MANUAL_FILE"; fi
        if [ "$config_existed" -eq 1 ]; then install -o root -g root -m 0644 "$backup_config" "$CONFIG_FILE"; else rm -f "$CONFIG_FILE"; fi
        echo -e "${RED}配置提交失败，已回滚。${NC}" >&2; exit 1
    fi
    echo '配置文件下载并验证成功。'
    break
done
