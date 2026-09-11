#!/bin/bash
set -Eeuo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
MANUAL_FILE=/etc/sing-box/manual.conf
DEFAULTS_FILE=/etc/sing-box/defaults.conf
CONFIG_FILE=/etc/sing-box/config.json
TMP_DIR=/tmp/sbshell-config
LOCK_FILE=/run/sbshell/config.lock

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
install -d -o root -g root -m 0700 /run/sbshell
read_value() { local key="$1" file="$2"; awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$file" 2>/dev/null || true; }
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
# 与 manual_input.sh 完全一致：后端地址允许留空，此时直接使用配置文件地址。
build_full_url() {
    if [ -n "$BACKEND_URL" ]; then
        FULL_URL="${BACKEND_URL%/}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"
    else
        FULL_URL="$TEMPLATE_URL"
    fi
}
validate_endpoints() {
    if [ -n "$BACKEND_URL" ]; then
        valid_url "$BACKEND_URL" || { echo -e "${RED}后端地址必须是 HTTPS URL。${NC}" >&2; return 1; }
        [ -n "$SUBSCRIPTION_URL" ] || { echo -e "${RED}使用后端地址时订阅地址不能为空。${NC}" >&2; return 1; }
    fi
    valid_subscription "$SUBSCRIPTION_URL" || { echo -e "${RED}订阅地址包含非法字符。${NC}" >&2; return 1; }
    valid_url "$TEMPLATE_URL" || { echo -e "${RED}配置文件地址必须是 HTTPS URL。${NC}" >&2; return 1; }
    build_full_url
    valid_url "$FULL_URL" || { echo -e "${RED}生成的订阅 URL 无效。${NC}" >&2; return 1; }
    return 0
}

MODE=$(read_value MODE /etc/sing-box/mode.conf)
mkdir -p "$TMP_DIR"; chmod 0700 "$TMP_DIR"; trap 'rm -rf "$TMP_DIR"' EXIT

# 参数只接受 yes/y（交互式重新录入）；旧代码用 ^[Yy]$ 判定提示、却用 = 'yes' 判定写回，
# 导致 `manual_update.sh yes` 既不提示也不更新 manual.conf。
PROMPT_FLAG=0
case "${1:-}" in y|Y|yes|YES) PROMPT_FLAG=1 ;; esac

prompt_user_input() {
    local attempts=0
    while true; do
        read -rp '请输入后端地址(不填使用默认值；后端地址可留空): ' BACKEND_URL || { echo '无法读取输入。' >&2; return 1; }
        BACKEND_URL=${BACKEND_URL:-$(read_value BACKEND_URL "$DEFAULTS_FILE")}
        read -rp '请输入订阅地址(不填使用默认值): ' SUBSCRIPTION_URL || { echo '无法读取输入。' >&2; return 1; }
        SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$(read_value SUBSCRIPTION_URL "$DEFAULTS_FILE")}
        read -rp '请输入配置文件地址(不填使用默认值): ' TEMPLATE_URL || { echo '无法读取输入。' >&2; return 1; }
        if [ -z "$TEMPLATE_URL" ]; then
            case "$MODE" in
                TProxy) TEMPLATE_URL=$(read_value TPROXY_TEMPLATE_URL "$DEFAULTS_FILE") ;;
                TUN) TEMPLATE_URL=$(read_value TUN_TEMPLATE_URL "$DEFAULTS_FILE") ;;
                *) echo '未知模式，无法从默认值读取配置文件地址。' >&2; return 1 ;;
            esac
        fi
        if validate_endpoints; then return 0; fi
        attempts=$((attempts + 1))
        [ "$attempts" -lt 20 ] || { echo '输入错误次数过多，已取消。' >&2; return 1; }
    done
}

if [ "$PROMPT_FLAG" -eq 1 ]; then
    prompt_user_input || exit 1
else
    [ -f "$MANUAL_FILE" ] || { echo -e "${RED}未找到手动配置，请先设置。${NC}"; exit 1; }
    BACKEND_URL=$(read_value BACKEND_URL "$MANUAL_FILE")
    SUBSCRIPTION_URL=$(read_value SUBSCRIPTION_URL "$MANUAL_FILE")
    TEMPLATE_URL=$(read_value TEMPLATE_URL "$MANUAL_FILE")
    validate_endpoints || exit 1
fi

[ ! -L "$LOCK_FILE" ] || { echo "锁文件是符号链接，拒绝使用: $LOCK_FILE" >&2; exit 1; }
exec 9>"$LOCK_FILE"
flock -x 9
if [ "$PROMPT_FLAG" -eq 1 ]; then
    printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TEMPLATE_URL" > "$TMP_DIR/manual.conf"
fi
[ -f "$MANUAL_FILE" ] && cp -a "$MANUAL_FILE" "$TMP_DIR/manual.backup" || true
[ -f "$CONFIG_FILE" ] && cp -a "$CONFIG_FILE" "$TMP_DIR/config.backup" || true

TMP_CONFIG="$TMP_DIR/config.json"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$FULL_URL" -o "$TMP_CONFIG" || { echo -e "${RED}配置下载失败。${NC}"; exit 1; }
sing-box check -c "$TMP_CONFIG" || { echo -e "${RED}新配置验证失败。${NC}"; exit 1; }
if [ "$PROMPT_FLAG" -eq 1 ]; then install -o root -g root -m 0600 "$TMP_DIR/manual.conf" "$MANUAL_FILE"; fi
install -o root -g root -m 0644 "$TMP_CONFIG" "$CONFIG_FILE"
if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
    [ ! -f "$TMP_DIR/manual.backup" ] || install -o root -g root -m 0600 "$TMP_DIR/manual.backup" "$MANUAL_FILE"
    [ ! -f "$TMP_DIR/config.backup" ] || install -o root -g root -m 0644 "$TMP_DIR/config.backup" "$CONFIG_FILE"
    systemctl restart sing-box || true
    echo -e "${RED}新配置启动失败，已恢复旧配置。${NC}" >&2
    exit 1
fi
echo -e "${GREEN}配置更新并启动成功。${NC}"
