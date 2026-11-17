#!/bin/bash
set -Eeuo pipefail
CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
CONFIG_FILE=/etc/sing-box/config.json
command -v sing-box >/dev/null 2>&1 || { echo -e "${RED}未找到 sing-box。${NC}" >&2; exit 1; }
[ -s "$CONFIG_FILE" ] || { echo -e "${RED}配置文件不存在或为空: $CONFIG_FILE${NC}" >&2; exit 1; }
echo -e "${CYAN}检查配置文件 $CONFIG_FILE ...${NC}"
sing-box check -c "$CONFIG_FILE" || { echo -e "${RED}配置文件验证失败。${NC}" >&2; exit 1; }
echo -e "${CYAN}配置文件验证通过。${NC}"

# C1：原先用 sed 的「type 行 → 首个单独的 }」范围，字段顺序一变（例如 dashboard 写在
# listen/secret 之前）就会在嵌套子对象的 } 处提前截断，把 secret/listen 读空并误报安全警告。
# 这里先用 awk 做花括号配对，取出完整的 "type": "api" service 对象（含嵌套 dashboard），
# 再沿用原来的 sed 解析与告警逻辑（输出文案不变）。
api_range=$(awk '
    function scan(s,   i, c, n) {
        # 先抹掉字符串内容，避免 "path": "a}b" 之类的括号干扰配对
        gsub(/"[^"]*"/, "", s)
        n = length(s)
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (c == "{") depth++
            else if (c == "}") {
                if (depth == 0) return 1   # service 对象的收尾 }（嵌套的都已配对完）
                depth--
            }
        }
        return 0
    }
    {
        if (!started) {
            if (match($0, /"type"[[:space:]]*:[[:space:]]*"api"/)) {
                started = 1; start = NR; depth = 0
                # type 之前的花括号属于外层对象，从 "api" 之后开始配对
                if (scan(substr($0, RSTART + RLENGTH))) { print start "," NR; done = 1; exit }
            }
            next
        }
        if (scan($0)) { print start "," NR; done = 1; exit }
    }
    END { if (started && !done) print start "," NR }
' "$CONFIG_FILE" 2>/dev/null || true)
api_block=''
if [ -n "$api_range" ]; then
    api_block=$(sed -n "${api_range}p" "$CONFIG_FILE" 2>/dev/null | head -n 80 || true)
fi
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
