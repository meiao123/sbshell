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
acquire_lock() {
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then sleep 1; continue; fi
        now=$(date +%s); created=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
        if [ "$created" -gt 0 ] && [ $((now - created)) -ge "$LOCK_TIMEOUT" ]; then rm -rf "$LOCK_DIR"; continue; fi
        sleep 1
done
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"; rm -rf "$TMP_DIR"' EXIT INT TERM
}
MODE=$(read_value MODE "$MODE_FILE")

if [ "${1:-}" = "yes" ]; then
    read -rp '后端地址(留空使用默认): ' BACKEND_URL
    BACKEND_URL=${BACKEND_URL:-$(read_value BACKEND_URL "$DEFAULTS_FILE")}
    read -rp '订阅地址(留空使用默认): ' SUBSCRIPTION_URL
    SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$(read_value SUBSCRIPTION_URL "$DEFAULTS_FILE")}
    read -rp '配置文件地址(留空使用默认): ' TEMPLATE_URL
    if [ -z "$TEMPLATE_URL" ]; then
        case "$MODE" in
            TProxy) TEMPLATE_URL=$(read_value TPROXY_TEMPLATE_URL "$DEFAULTS_FILE");;
            TUN) TEMPLATE_URL=$(read_value TUN_TEMPLATE_URL "$DEFAULTS_FILE");;
            *) echo '未知模式。' >&2; exit 1;;
        esac
    fi
    printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TEMPLATE_URL" > "$TMP_DIR/manual.conf"
else
    [ -f "$MANUAL_FILE" ] || { echo '未找到 manual.conf，请先配置。' >&2; exit 1; }
    BACKEND_URL=$(read_value BACKEND_URL "$MANUAL_FILE")
    SUBSCRIPTION_URL=$(read_value SUBSCRIPTION_URL "$MANUAL_FILE")
    TEMPLATE_URL=$(read_value TEMPLATE_URL "$MANUAL_FILE")
fi

valid_url "$BACKEND_URL" && [ -n "$SUBSCRIPTION_URL" ] && valid_url "$TEMPLATE_URL" || { echo 'manual.conf 配置无效。' >&2; exit 1; }
FULL_URL="${BACKEND_URL%/}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"

acquire_lock
if [ -f "$MANUAL_FILE" ]; then cp -a "$MANUAL_FILE" "$TMP_DIR/manual.backup"; fi
if [ -f "$CONFIG_FILE" ]; then cp -a "$CONFIG_FILE" "$TMP_DIR/config.backup"; fi

curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$FULL_URL" -o "$TMP_DIR/config.json" || { echo '配置下载失败。' >&2; exit 1; }
sing-box check -c "$TMP_DIR/config.json" || { echo '配置验证失败。' >&2; exit 1; }

if [ "${1:-}" = "yes" ]; then install -o root -g root -m 0600 "$TMP_DIR/manual.conf" "$MANUAL_FILE"; fi
install -o root -g root -m 0644 "$TMP_DIR/config.json" "$CONFIG_FILE"

if ! /etc/init.d/sing-box restart || ! sleep 2 || ! pidof sing-box >/dev/null 2>&1; then
    [ ! -f "$TMP_DIR/manual.backup" ] || install -o root -g root -m 0600 "$TMP_DIR/manual.backup" "$MANUAL_FILE"
    [ ! -f "$TMP_DIR/config.backup" ] || install -o root -g root -m 0644 "$TMP_DIR/config.backup" "$CONFIG_FILE"
    /etc/init.d/sing-box restart || true
    echo -e "${RED}新配置启动失败，已恢复旧配置。${NC}" >&2
    exit 1
fi

echo -e "${GREEN}配置更新并启动成功。${NC}"
