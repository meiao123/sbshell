#!/bin/bash
set -Eeuo pipefail
CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
CONFIG_FILE=/etc/sing-box/config.json
command -v sing-box >/dev/null 2>&1 || { echo -e "${RED}未找到 sing-box。${NC}" >&2; exit 1; }
[ -s "$CONFIG_FILE" ] || { echo -e "${RED}配置文件不存在或为空: $CONFIG_FILE${NC}" >&2; exit 1; }
echo -e "${CYAN}检查配置文件 $CONFIG_FILE ...${NC}"
sing-box check -c "$CONFIG_FILE" || { echo -e "${RED}配置文件验证失败。${NC}" >&2; exit 1; }
echo -e "${CYAN}配置文件验证通过。${NC}"

api_block=$(sed -n '/"type"[[:space:]]*:[[:space:]]*"api"/,/^[[:space:]]*}[,]*[[:space:]]*$/p' "$CONFIG_FILE" 2>/dev/null | head -n 80 || true)
if printf '%s\n' "$api_block" | grep -Eq '"dashboard"[[:space:]]*:[[:space:]]*\{' &&
   printf '%s\n' "$api_block" | grep -Eq '"enabled"[[:space:]]*:[[:space:]]*true'; then
    api_listen=$(printf '%s\n' "$api_block" | sed -n 's/.*"listen"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    api_port=$(printf '%s\n' "$api_block" | sed -n 's/.*"listen_port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)
    api_secret=$(printf '%s\n' "$api_block" | sed -n 's/.*"secret"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    echo "检测到 sing-box 1.14+ API Dashboard: ${api_listen:-?}:${api_port:-?}/dashboard/"
    if [ -z "$api_secret" ]; then
        case "$api_listen" in
            127.0.0.1|localhost|'::1'|'[::1]') ;;
            *) echo -e "${RED}安全警告：API 不是仅本机监听且 secret 为空，身份认证已关闭。${NC}" >&2 ;;
        esac
    fi
fi

if grep -Eq '"type"[[:space:]]*:[[:space:]]*"tun"' "$CONFIG_FILE" &&
   grep -Eq '"auto_route"[[:space:]]*:[[:space:]]*true' "$CONFIG_FILE" &&
   grep -Eq '"auto_redirect"[[:space:]]*:[[:space:]]*true' "$CONFIG_FILE"; then
    echo -e "${CYAN}检测到 TUN auto_route + auto_redirect：由 sing-box 负责 OpenWrt fw4 集成，Sbshell 不需要再生成额外 TUN 转发规则。${NC}"
fi
