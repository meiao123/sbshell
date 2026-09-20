#!/bin/bash
set -Eeuo pipefail
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
SCRIPT_DIR=/etc/sing-box/scripts

read -rp '是否停止 sing-box?(y/n): ' confirm_stop
[[ "$confirm_stop" =~ ^[Yy]$ ]] || { echo -e "${CYAN}已取消。${NC}"; exit 0; }
if ! pidof sing-box >/dev/null 2>&1; then
    echo -e "${GREEN}sing-box 未运行，无需重复停止。${NC}"
    exit 0
fi
if ! /etc/init.d/sing-box stop 2> >(sed '/^Command failed:.*Not found/d' >&2); then
    echo -e "${RED}停止 sing-box 失败。${NC}" >&2
    exit 1
fi
echo -e "${GREEN}sing-box 已停止。${NC}"
read -rp '是否清理 sing-box 防火墙规则？(y/n): ' confirm_cleanup
if [[ "$confirm_cleanup" =~ ^[Yy]$ ]]; then
    # A-23：clean_nft.sh 失败时，set -e 会让脚本在没有任何解释的情况下退出 ——
    # 用户只看到“sing-box 已停止”，不知道规则是否还挂在链上。这里显式报错并给出手工命令。
    if ! bash "$SCRIPT_DIR/clean_nft.sh"; then
        echo -e "${RED}sing-box 防火墙规则清理失败（sing-box 已停止）。${NC}" >&2
        echo -e "${YELLOW}可手工重试：bash $SCRIPT_DIR/clean_nft.sh${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}sing-box 防火墙规则清理完成。${NC}"
fi
