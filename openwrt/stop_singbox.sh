#!/bin/bash
set -Eeuo pipefail
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
SCRIPT_DIR=/etc/sing-box/scripts

read -rp '是否停止 sing-box?(y/n): ' confirm_stop
[[ "$confirm_stop" =~ ^[Yy]$ ]] || { echo -e "${CYAN}已取消。${NC}"; return 0 2>/dev/null || exit 0; }
if ! pidof sing-box >/dev/null 2>&1; then
    echo -e "${GREEN}sing-box 未运行，无需重复停止。${NC}"
    exit 0
fi
if ! /etc/init.d/sing-box stop 2> >(sed '/^Command failed: Not found$/d' >&2); then
    echo -e "${RED}停止 sing-box 失败。${NC}" >&2
    exit 1
fi
echo -e "${GREEN}sing-box 已停止。${NC}"
read -rp '是否清理 sing-box 防火墙规则？(y/n): ' confirm_cleanup
if [[ "$confirm_cleanup" =~ ^[Yy]$ ]]; then
    bash "$SCRIPT_DIR/clean_nft.sh"
    echo -e "${GREEN}sing-box 防火墙规则清理完成。${NC}"
fi
