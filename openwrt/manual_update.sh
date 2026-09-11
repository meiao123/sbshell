#!/bin/bash
set -Eeuo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
MANUAL_FILE=/etc/sing-box/manual.conf
DEFAULTS_FILE=/etc/sing-box/defaults.conf
CONFIG_FILE=/etc/sing-box/config.json
TMP_DIR=$(mktemp -d /tmp/sbshell-config.XXXXXX); trap 'rm -rf "$TMP_DIR"' EXIT
read_value(){ awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,"");print;exit}' "$2" 2>/dev/null || true; }
valid_url(){ [[ "$1" =~ ^https://[^[:space:]]+$ ]]; }
MODE=$(read_value MODE /etc/sing-box/mode.conf)

if [ "${1:-}" = "yes" ]; then
  read -rp '后端地址(留空使用默认): ' BACKEND_URL; BACKEND_URL=${BACKEND_URL:-$(read_value BACKEND_URL "$DEFAULTS_FILE")}
  read -rp '订阅地址(留空使用默认): ' SUBSCRIPTION_URL; SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$(read_value SUBSCRIPTION_URL "$DEFAULTS_FILE")}
  read -rp '配置文件地址(留空使用默认): ' TEMPLATE_URL
  if [ -z "$TEMPLATE_URL" ]; then case "$MODE" in TProxy) TEMPLATE_URL=$(read_value TPROXY_TEMPLATE_URL "$DEFAULTS_FILE");; TUN) TEMPLATE_URL=$(read_value TUN_TEMPLATE_URL "$DEFAULTS_FILE");; *) echo '未知模式。' >&2; exit 1;; esac; fi
  valid_url "$BACKEND_URL" && [ -n "$SUBSCRIPTION_URL" ] && valid_url "$TEMPLATE_URL" || { echo '配置地址无效。' >&2; exit 1; }
  printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TEMPLATE_URL" > "$TMP_DIR/manual.conf"
  install -o root -g root -m 0600 "$TMP_DIR/manual.conf" "$MANUAL_FILE"
else
  [ -f "$MANUAL_FILE" ] || { echo '未找到 manual.conf，请先配置。' >&2; exit 1; }
  BACKEND_URL=$(read_value BACKEND_URL "$MANUAL_FILE"); SUBSCRIPTION_URL=$(read_value SUBSCRIPTION_URL "$MANUAL_FILE"); TEMPLATE_URL=$(read_value TEMPLATE_URL "$MANUAL_FILE")
fi
valid_url "$BACKEND_URL" && [ -n "$SUBSCRIPTION_URL" ] && valid_url "$TEMPLATE_URL" || { echo 'manual.conf 配置无效。' >&2; exit 1; }
FULL_URL="${BACKEND_URL}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"
TMP_CONFIG="$TMP_DIR/config.json"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$FULL_URL" -o "$TMP_CONFIG" || { echo '配置下载失败。' >&2; exit 1; }
sing-box check -c "$TMP_CONFIG" || { echo '配置验证失败。' >&2; exit 1; }
[ ! -f "$CONFIG_FILE" ] || cp -a "$CONFIG_FILE" "$CONFIG_FILE.backup"
install -o root -g root -m 0644 "$TMP_CONFIG" "$CONFIG_FILE"
if ! /etc/init.d/sing-box restart; then
  [ ! -f "$CONFIG_FILE.backup" ] || install -o root -g root -m 0644 "$CONFIG_FILE.backup" "$CONFIG_FILE"
  /etc/init.d/sing-box restart || true
  exit 1
fi
sleep 2
pidof sing-box >/dev/null || { echo -e "${RED}sing-box 启动失败。${NC}" >&2; exit 1; }
echo -e "${GREEN}配置更新并启动成功。${NC}"
