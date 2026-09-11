#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

install_ufw() {
    command -v ufw >/dev/null 2>&1 && return 0
    apt-get update
    apt-get install -y ufw
    command -v ufw >/dev/null 2>&1
}

# 当前 SSH 实际监听的端口。默认 `ufw allow ssh` 只放行 22，如果用户把 sshd 改到别的端口，
# 开启 `default deny incoming` 后新连接会被挡在外面（当前会话因为有 conntrack 还活着，
# 重连时才暴露问题）。这里按 ss → sshd_config → $SSH_CONNECTION 的顺序推断。
detect_ssh_ports() {
    local ports='' port
    if command -v ss >/dev/null 2>&1; then
        ports=$(ss -H -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | sort -un | tr '\n' ' ')
    fi
    if [ -z "${ports// /}" ] && [ -f /etc/ssh/sshd_config ]; then
        ports=$(awk '/^[[:space:]]*Port[[:space:]]+/ {print $2}' /etc/ssh/sshd_config | sort -un | tr '\n' ' ')
    fi
    if [ -z "${ports// /}" ] && [ -n "${SSH_CONNECTION:-}" ]; then
        port=$(awk '{print $4}' <<< "$SSH_CONNECTION")
        [ -n "$port" ] && ports="$port"
    fi
    [ -n "${ports// /}" ] || ports='22'
    printf '%s\n' "$ports"
}

# 解析 sing-box 配置里的所有 listen_port，避免服务端配置实际监听的端口被默认策略挡住
# （内置默认服务端配置使用 80/tcp、443/tcp 和 52021/udp）。
detect_singbox_ports() {
    local cfg=/etc/sing-box/config.json
    [ -s "$cfg" ] || return 0
    grep -o '"listen_port"[[:space:]]*:[[:space:]]*[0-9]\+' "$cfg" 2>/dev/null | grep -o '[0-9]\+$' | sort -un | tr '\n' ' '
}

install_ufw || { echo -e "${RED}UFW 安装失败。${NC}" >&2; exit 1; }
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

SSH_PORTS=$(detect_ssh_ports)
for port in $SSH_PORTS; do
    ufw allow "$port"/tcp >/dev/null
done
echo -e "${CYAN}已放行检测到的 SSH 端口: ${SSH_PORTS:-22}${NC}"
ufw allow ssh >/dev/null
ufw allow http >/dev/null
ufw allow https >/dev/null

for port in $(detect_singbox_ports); do
    ufw allow "$port"/tcp >/dev/null
    ufw allow "$port"/udp >/dev/null
    echo -e "${GREEN}已放行 sing-box 监听端口 $port (TCP/UDP)。${NC}"
done

if [ "${1:-}" = "--auto" ]; then
    ufw --force enable >/dev/null
    echo -e "${GREEN}UFW 自动配置完成。${NC}"
    exit 0
fi

echo -e "${CYAN}请输入需要放行的端口（空格或英文逗号分隔）。${NC}"
read -rp "要放行的端口: " ports_input
ports=$(tr ',' ' ' <<< "$ports_input")
for port in $ports; do
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        ufw allow "$port"/tcp >/dev/null
        ufw allow "$port"/udp >/dev/null
        echo -e "${GREEN}已放行端口 $port (TCP/UDP)。${NC}"
    else
        echo -e "${YELLOW}已跳过无效端口: $port${NC}"
    fi
done

ufw --force enable >/dev/null

echo -e "${CYAN}是否需要修改 SSH 端口？(y/n)${NC}"
read -rp "选择 [n]: " ssh_modify
if [[ "$ssh_modify" =~ ^[Yy]$ ]]; then
    read -rp "请输入新的 SSH 端口 (1025-65535): " new_ssh_port
    if [[ "$new_ssh_port" =~ ^[0-9]+$ ]] && [ "$new_ssh_port" -ge 1025 ] && [ "$new_ssh_port" -le 65535 ]; then
        backup="/etc/ssh/sshd_config.bak.$(date +%s)"
        cp -a /etc/ssh/sshd_config "$backup"
        if grep -qE '^[[:space:]]*#?[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
            sed -i -E "s/^[[:space:]]*#?[[:space:]]*Port[[:space:]]+.*/Port $new_ssh_port/" /etc/ssh/sshd_config
        else
            echo "Port $new_ssh_port" >> /etc/ssh/sshd_config
        fi
        if sshd -t; then
            # 先放行新端口，再重启 sshd，避免中间窗口把自己锁在外面。
            ufw allow "$new_ssh_port"/tcp >/dev/null
            systemctl restart sshd || systemctl restart ssh
            echo -e "${GREEN}SSH 已切换到端口 $new_ssh_port（旧端口仍然放行，确认可登录后可自行删除）。${NC}"
        else
            cp -a "$backup" /etc/ssh/sshd_config
            echo -e "${RED}新的 SSH 配置校验失败，已恢复。${NC}" >&2
            exit 1
        fi
    else
        echo -e "${RED}端口输入无效，未修改 SSH 端口。${NC}"
    fi
fi

echo -e "${GREEN}UFW 防火墙配置完成。${NC}"
