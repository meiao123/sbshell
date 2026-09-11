#!/bin/bash
set -Eeuo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; MAGENTA='\033[0;35m'; NC='\033[0m'
[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
SCRIPT_DIR=/etc/sing-box/scripts
MODE=$(sed -n 's/^MODE=//p' /etc/sing-box/mode.conf 2>/dev/null | head -n1)

if pidof sing-box >/dev/null 2>&1; then
    echo -e "${GREEN}sing-box 已在运行，无需重复启动。${NC}"
    exit 0
fi

case "$MODE" in
    TProxy) bash "$SCRIPT_DIR/configure_tproxy.sh" ;;
    TUN) bash "$SCRIPT_DIR/configure_tun.sh" ;;
    *) echo -e "${RED}未知代理模式: $MODE${NC}" >&2; exit 1 ;;
esac

if ! /etc/init.d/sing-box start 2> >(sed '/^Command failed: Not found$/d' >&2); then
    echo -e "${RED}sing-box 启动失败。${NC}" >&2
    exit 1
fi
sleep 2
if ! pidof sing-box >/dev/null 2>&1; then
    echo -e "${RED}sing-box 未运行，请检查日志。${NC}" >&2
    exit 1
fi
echo -e "${GREEN}sing-box 启动成功，当前模式: ${MAGENTA}$MODE${NC}"
