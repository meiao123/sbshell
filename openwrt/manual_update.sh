#!/bin/bash
set -Eeuo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
MANUAL_FILE=/etc/sing-box/manual.conf
DEFAULTS_FILE=/etc/sing-box/defaults.conf
CONFIG_FILE=/etc/sing-box/config.json
MODE_FILE=/etc/sing-box/mode.conf
LOCK_DIR=/tmp/sbshell-config.lock
LOCK_TIMEOUT=900
TMP_DIR=$(mktemp -d /tmp/sbshell-config.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

read_value() { awk -F= -v k="$1" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$2" 2>/dev/null || true; }
valid_url() { [[ "$1" =~ ^https://[^[:space:]]+$ ]]; }
valid_subscription() {
    local value="$1"
    [ -z "$value" ] && return 0
    case "$value" in
        *[[:space:]]*|*'&file='*|*'#'*) return 1 ;;
    esac
    return 0
}
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
release_lock() {
    [ -d "$LOCK_DIR" ] || return 0
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    [ "$owner" = "$$" ] && rm -rf "$LOCK_DIR"
}
acquire_lock() {
        waited=0
        while ! mkdir "$LOCK_DIR" 2>/dev/null; do
            owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
            # pid 必须是纯数字，否则视为无效
            case "$owner" in ''|*[!0-9]*) owner='' ;; esac
            now=$(date +%s)
            created=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
            age=0
            [ "$created" -gt 0 ] && age=$((now - created))
            # 过期即接管：不能只凭 owner 是否存活判断（pid 复用或伪造 pid 会让
            # 过期分支永远到不了，配置更新会永久阻塞）
            if [ "$age" -ge "$LOCK_TIMEOUT" ]; then
                rm -rf "$LOCK_DIR" 2>/dev/null || true
                sleep 1
                continue
            fi
            if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
                waited=$((waited + 1))
                if [ "$waited" -ge "$LOCK_TIMEOUT" ]; then
                    echo '等待配置锁超时（另一个进程持锁）。' >&2
                    return 1
                fi
            fi
            sleep 1
        done
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        trap 'release_lock; rm -rf "$TMP_DIR"' EXIT
        trap 'release_lock; rm -rf "$TMP_DIR"; exit 1' INT TERM
    }
MODE=$(read_value MODE "$MODE_FILE")

PROMPT_FLAG=0
case "${1:-}" in y|Y|yes|YES) PROMPT_FLAG=1 ;; esac

prompt_user_input() {
    local attempts=0
    while true; do
        read -rp '后端地址(留空使用默认，后端地址可留空): ' BACKEND_URL || { echo '无法读取输入。' >&2; return 1; }
        BACKEND_URL=${BACKEND_URL:-$(read_value BACKEND_URL "$DEFAULTS_FILE")}
        read -rp '订阅地址(留空使用默认): ' SUBSCRIPTION_URL || { echo '无法读取输入。' >&2; return 1; }
        SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$(read_value SUBSCRIPTION_URL "$DEFAULTS_FILE")}
        read -rp '配置文件地址(留空使用默认): ' TEMPLATE_URL || { echo '无法读取输入。' >&2; return 1; }
        if [ -z "$TEMPLATE_URL" ]; then
            case "$MODE" in
                TProxy) TEMPLATE_URL=$(read_value TPROXY_TEMPLATE_URL "$DEFAULTS_FILE");;
                TUN) TEMPLATE_URL=$(read_value TUN_TEMPLATE_URL "$DEFAULTS_FILE");;
                *) echo '未知模式，无法从默认值读取配置文件地址。' >&2; return 1;;
            esac
        fi
        if validate_endpoints; then return 0; fi
        attempts=$((attempts + 1))
        [ "$attempts" -lt 20 ] || { echo '输入错误次数过多，已取消。' >&2; return 1; }
    done
}

if [ "$PROMPT_FLAG" -eq 1 ]; then
    prompt_user_input || exit 1
    printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TEMPLATE_URL" > "$TMP_DIR/manual.conf"
else
    [ -f "$MANUAL_FILE" ] || { echo '未找到 manual.conf，请先配置。' >&2; exit 1; }
    BACKEND_URL=$(read_value BACKEND_URL "$MANUAL_FILE")
    SUBSCRIPTION_URL=$(read_value SUBSCRIPTION_URL "$MANUAL_FILE")
    TEMPLATE_URL=$(read_value TEMPLATE_URL "$MANUAL_FILE")
    validate_endpoints || exit 1
fi

acquire_lock
if [ -f "$MANUAL_FILE" ]; then cp -a "$MANUAL_FILE" "$TMP_DIR/manual.backup"; fi
if [ -f "$CONFIG_FILE" ]; then cp -a "$CONFIG_FILE" "$TMP_DIR/config.backup"; fi

curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$FULL_URL" -o "$TMP_DIR/config.json" || { echo '配置下载失败。' >&2; exit 1; }
sing-box check -c "$TMP_DIR/config.json" || { echo '配置验证失败。' >&2; exit 1; }

if [ "$PROMPT_FLAG" -eq 1 ]; then install -o root -g root -m 0600 "$TMP_DIR/manual.conf" "$MANUAL_FILE"; fi
install -o root -g root -m 0600 "$TMP_DIR/config.json" "$CONFIG_FILE"

if ! /etc/init.d/sing-box restart || ! sleep 2 || ! pidof sing-box >/dev/null 2>&1; then
    [ ! -f "$TMP_DIR/manual.backup" ] || install -o root -g root -m 0600 "$TMP_DIR/manual.backup" "$MANUAL_FILE"
    [ ! -f "$TMP_DIR/config.backup" ] || install -o root -g root -m 0600 "$TMP_DIR/config.backup" "$CONFIG_FILE"
    /etc/init.d/sing-box restart || true
    echo -e "${RED}新配置启动失败，已恢复旧配置。${NC}" >&2
    exit 1
fi

echo -e "${GREEN}配置更新并启动成功。${NC}"
