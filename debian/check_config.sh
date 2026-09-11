#!/bin/bash
set -Eeuo pipefail
CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
CONFIG_FILE=/etc/sing-box/config.json

command -v sing-box >/dev/null 2>&1 || { echo -e "${RED}未找到 sing-box。${NC}" >&2; exit 1; }
[ -s "$CONFIG_FILE" ] || { echo -e "${RED}配置文件不存在或为空: $CONFIG_FILE${NC}" >&2; exit 1; }
echo -e "${CYAN}检查配置文件 $CONFIG_FILE ...${NC}"
if sing-box check -c "$CONFIG_FILE"; then
    echo -e "${CYAN}配置文件验证通过。${NC}"
else
    echo -e "${RED}配置文件验证失败。${NC}" >&2
    exit 1
fi
