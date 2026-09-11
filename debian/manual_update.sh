#!/bin/bash
set -Eeuo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
MANUAL_FILE=/etc/sing-box/manual.conf
DEFAULTS_FILE=/etc/sing-box/defaults.conf
CONFIG_FILE=/etc/sing-box/config.json
TMP_DIR=/tmp/sbshell-config
LOCK_FILE=/run/lock/sbshell-config.lock

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
install -d -o root -g root -m 0755 /run/lock
read_value() { local key="$1" file="$2"; awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$file" 2>/dev/null || true; }
valid_url() { [[ "$1" =~ ^https://[^[:space:]]+$ ]]; }
MODE=$(read_value MODE /etc/sing-box/mode.conf)
mkdir -p "$TMP_DIR"; chmod 0700 "$TMP_DIR"; trap 'rm -rf "$TMP_DIR"' EXIT

prompt_user_input() {
    while true; do
        read -rp '请输入后端地址(不填使用默认值): ' BACKEND_URL
        BACKEND_URL=${BACKEND_URL:-$(read_value BACKEND_URL "$DEFAULTS_FILE")}
        valid_url "$BACKEND_URL" && break
    done
    while true; do
        read -rp '请输入订阅地址(不填使用默认值): ' SUBSCRIPTION_URL
        SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$(read_value SUBSCRIPTION_URL "$DEFAULTS_FILE")}
        [ -n "$SUBSCRIPTION_URL" ] && break
    done
    while true; do
        read -rp '请输入配置文件地址(不填使用默认值): ' TEMPLATE_URL
        if [ -z "$TEMPLATE_URL" ]; then case "$MODE" in TProxy) TEMPLATE_URL=$(read_value TPROXY_TEMPLATE_URL "$DEFAULTS_FILE");; TUN) TEMPLATE_URL=$(read_value TUN_TEMPLATE_URL "$DEFAULTS_FILE");; *) return 1;; esac; fi
        valid_url "$TEMPLATE_URL" && break
    done
}

if [[ "${1:-}" =~ ^[Yy]$ ]]; then
    prompt_user_input
else
    [ -f "$MANUAL_FILE" ] || { echo -e "${RED}未找到手动配置，请先设置。${NC}"; exit 1; }
    BACKEND_URL=$(read_value BACKEND_URL "$MANUAL_FILE")
    SUBSCRIPTION_URL=$(read_value SUBSCRIPTION_URL "$MANUAL_FILE")
    TEMPLATE_URL=$(read_value TEMPLATE_URL "$MANUAL_FILE")
fi
valid_url "$BACKEND_URL" && [ -n "$SUBSCRIPTION_URL" ] && valid_url "$TEMPLATE_URL" || { echo -e "${RED}配置地址无效。${NC}"; exit 1; }
FULL_URL="${BACKEND_URL%/}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"

exec 9>"$LOCK_FILE"
flock -x 9
[ "${1:-}" = 'yes' ] && printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TEMPLATE_URL" > "$TMP_DIR/manual.conf"
[ -f "$MANUAL_FILE" ] && cp -a "$MANUAL_FILE" "$TMP_DIR/manual.backup" || true
[ -f "$CONFIG_FILE" ] && cp -a "$CONFIG_FILE" "$TMP_DIR/config.backup" || true

TMP_CONFIG="$TMP_DIR/config.json"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$FULL_URL" -o "$TMP_CONFIG" || { echo -e "${RED}配置下载失败。${NC}"; exit 1; }
sing-box check -c "$TMP_CONFIG" || { echo -e "${RED}新配置验证失败。${NC}"; exit 1; }
[ "${1:-}" = 'yes' ] && install -o root -g root -m 0600 "$TMP_DIR/manual.conf" "$MANUAL_FILE"
install -o root -g root -m 0644 "$TMP_CONFIG" "$CONFIG_FILE"
if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
    [ ! -f "$TMP_DIR/manual.backup" ] || install -o root -g root -m 0600 "$TMP_DIR/manual.backup" "$MANUAL_FILE"
    [ ! -f "$TMP_DIR/config.backup" ] || install -o root -g root -m 0644 "$TMP_DIR/config.backup" "$CONFIG_FILE"
    systemctl restart sing-box || true
    echo -e "${RED}新配置启动失败，已恢复旧配置。${NC}" >&2
    exit 1
fi
echo -e "${GREEN}配置更新并启动成功。${NC}"
