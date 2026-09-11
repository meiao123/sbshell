#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

MANUAL_FILE=/etc/sing-box/manual.conf
DEFAULTS_FILE=/etc/sing-box/defaults.conf
CONFIG_FILE=/etc/sing-box/config.json
MODE_FILE=/etc/sing-box/mode.conf
LOCK_DIR=/tmp/sbshell-config.lock
LOCK_TIMEOUT=900

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

get_default() {
    local key="$1"
    grep -m1 "^${key}=" "$DEFAULTS_FILE" 2>/dev/null | cut -d'=' -f2- || true
}
valid_url() { [[ "$1" =~ ^https://[^[:space:]]+$ ]]; }
# 订阅地址不是 URL（是后端约定的查询串），但必须排除空白、'#' 以及会覆盖 file 参数的片段。
valid_subscription() {
    local value="$1"
    [ -z "$value" ] && return 0
    case "$value" in
        *[[:space:]]*|*'&file='*|*'#'*) return 1 ;;
    esac
    return 0
}

acquire_lock() {
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
            sleep 1
            continue
        fi
        now=$(date +%s)
        created=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
        if [ "$created" -gt 0 ] && [ $((now - created)) -ge "$LOCK_TIMEOUT" ]; then
            rm -rf "$LOCK_DIR"
            continue
        fi
        sleep 1
done
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    # 这里必须接管 EXIT 清理：后设置的 EXIT trap 会覆盖前面的 `trap cleanup EXIT`，
    # 否则 TMP_FILES 里的临时文件（含配置备份）永远不会被删除。
    trap 'cleanup; rm -rf "$LOCK_DIR"' EXIT INT TERM
}

# busybox grep 不支持 -oP（PCRE），OpenWrt 默认就是 busybox，用 sed 解析 MODE。
MODE=$(sed -n 's/^MODE=//p' "$MODE_FILE" 2>/dev/null | head -n1)
TMP_FILES=()
# 使用 ${arr[@]+...} 兜底，避免老 bash 在 set -u 下对空数组报 unbound variable。
cleanup() { local file; for file in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do rm -f "$file" 2>/dev/null || true; done; }
trap cleanup EXIT

while true; do
    read -rp '请输入后端地址(回车使用默认值可留空): ' BACKEND_URL
    BACKEND_URL=${BACKEND_URL:-$(get_default BACKEND_URL)}
    read -rp '请输入订阅地址(回车使用默认值可留空): ' SUBSCRIPTION_URL
    SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$(get_default SUBSCRIPTION_URL)}
    read -rp '请输入配置文件地址(回车使用默认值可留空): ' TEMPLATE_URL
    if [ -z "$TEMPLATE_URL" ]; then
        case "$MODE" in
            TProxy) TEMPLATE_URL=$(get_default TPROXY_TEMPLATE_URL) ;;
            TUN) TEMPLATE_URL=$(get_default TUN_TEMPLATE_URL) ;;
            *) echo -e "${RED}未知的模式: $MODE${NC}"; exit 1 ;;
        esac
    fi

    echo -e "${CYAN}你输入的配置信息如下:${NC}"
    echo "后端地址: $BACKEND_URL"
    echo "订阅地址: $SUBSCRIPTION_URL"
    echo "配置文件地址: $TEMPLATE_URL"
    read -rp '确认输入的配置信息？(y/n): ' confirm_choice
    [[ "$confirm_choice" =~ ^[Yy]$ ]] || { echo -e "${RED}请重新输入配置信息。${NC}"; continue; }

    if [ -n "$BACKEND_URL" ] && ! valid_url "$BACKEND_URL"; then echo -e "${RED}后端地址必须是 HTTPS URL。${NC}"; continue; fi
    if [ -n "$TEMPLATE_URL" ] && ! valid_url "$TEMPLATE_URL"; then echo -e "${RED}配置文件地址必须是 HTTPS URL。${NC}"; continue; fi
    if ! valid_subscription "$SUBSCRIPTION_URL"; then echo -e "${RED}订阅地址包含非法字符（空白、# 或 &file=）。${NC}"; continue; fi
    if [ -n "$BACKEND_URL" ] && [ -z "$SUBSCRIPTION_URL" ]; then echo -e "${RED}使用后端地址时订阅地址不能为空。${NC}"; continue; fi

    acquire_lock
    install -d -o root -g root -m 0755 /etc/sing-box
    tmp_manual=$(mktemp /etc/sing-box/.manual.conf.XXXXXX)
    tmp_config=$(mktemp /etc/sing-box/.config.json.XXXXXX)
    backup_manual=$(mktemp /etc/sing-box/.manual.conf.backup.XXXXXX)
    backup_config=$(mktemp /etc/sing-box/.config.json.backup.XXXXXX)
    TMP_FILES+=("$tmp_manual" "$tmp_config" "$backup_manual" "$backup_config")
    manual_existed=0
    config_existed=0

    printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TEMPLATE_URL" > "$tmp_manual"
    if [ -f "$MANUAL_FILE" ]; then install -o root -g root -m 0600 "$MANUAL_FILE" "$backup_manual"; manual_existed=1; fi

    if [ -n "$BACKEND_URL" ] && [ -n "$SUBSCRIPTION_URL" ]; then
        FULL_URL="${BACKEND_URL%/}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"
    else
        FULL_URL="$TEMPLATE_URL"
    fi
    valid_url "$FULL_URL" || { echo -e "${RED}生成的订阅 URL 无效。${NC}" >&2; exit 1; }

    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$FULL_URL" -o "$tmp_config" || { echo -e "${RED}配置文件下载失败，未修改现有配置。${NC}" >&2; exit 1; }
    [ -s "$tmp_config" ] || { echo -e "${RED}下载的配置为空。${NC}" >&2; exit 1; }
    sing-box check -c "$tmp_config" || { echo -e "${RED}配置文件验证失败，未修改现有配置。${NC}" >&2; exit 1; }

    if [ -f "$CONFIG_FILE" ]; then install -o root -g root -m 0600 "$CONFIG_FILE" "$backup_config"; config_existed=1; fi
    chown root:root "$tmp_manual" "$tmp_config"
    chmod 0600 "$tmp_manual"; chmod 0644 "$tmp_config"

    mv -f "$tmp_manual" "$MANUAL_FILE"
    if ! mv -f "$tmp_config" "$CONFIG_FILE"; then
        if [ "$manual_existed" -eq 1 ]; then install -o root -g root -m 0600 "$backup_manual" "$MANUAL_FILE"; else rm -f "$MANUAL_FILE"; fi
        if [ "$config_existed" -eq 1 ]; then install -o root -g root -m 0644 "$backup_config" "$CONFIG_FILE"; else rm -f "$CONFIG_FILE"; fi
        echo -e "${RED}配置文件提交失败，已回滚。${NC}" >&2
        exit 1
    fi
    echo '配置文件下载并验证成功，manual.conf 与 config.json 已事务提交。'
    break
done
