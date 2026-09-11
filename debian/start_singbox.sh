#!/bin/bash
set -Eeuo pipefail
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
SCRIPT_DIR="/etc/sing-box/scripts"
MODE_FILE="/etc/sing-box/mode.conf"
MODE=$(awk -F= '$1 == "MODE" {print $2; exit}' "$MODE_FILE" 2>/dev/null || true)

if [[ "$MODE" == "TProxy" ]]; then
    bash "$SCRIPT_DIR/configure_tproxy.sh"
elif [[ "$MODE" == "TUN" ]]; then
    bash "$SCRIPT_DIR/configure_tun.sh"
else
    echo -e "${RED}未知代理模式: $MODE${NC}" >&2
    exit 1
fi

if ! systemctl restart sing-box; then
    echo -e "${RED}sing-box 启动失败。${NC}" >&2
    exit 1
fi
if ! systemctl is-active --quiet sing-box; then
    echo -e "${RED}sing-box 未处于 active 状态。${NC}" >&2
    exit 1
fi
echo -e "${GREEN}sing-box 启动成功，当前模式: $MODE${NC}"
