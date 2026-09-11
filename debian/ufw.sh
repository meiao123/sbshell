#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

install_ufw() {
    command -v ufw >/dev/null 2>&1 && return 0
    sudo apt-get update
    sudo apt-get install -y ufw
    command -v ufw >/dev/null 2>&1
}

install_ufw || { echo -e "${RED}UFW 安装失败。${NC}" >&2; exit 1; }
sudo ufw default deny incoming >/dev/null
sudo ufw default allow outgoing >/dev/null
sudo ufw allow ssh >/dev/null
sudo ufw allow http >/dev/null
sudo ufw allow https >/dev/null

if [ "${1:-}" = "--auto" ]; then
    sudo ufw --force enable >/dev/null
    echo -e "${GREEN}UFW 自动配置完成。${NC}"
    exit 0
fi

echo -e "${CYAN}请输入需要放行的端口（空格或英文逗号分隔）。${NC}"
read -rp "要放行的端口: " ports_input
ports=$(tr ',' ' ' <<< "$ports_input")
for port in $ports; do
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        sudo ufw allow "$port"/tcp >/dev/null
        sudo ufw allow "$port"/udp >/dev/null
        echo -e "${GREEN}已放行端口 $port (TCP/UDP)。${NC}"
    else
        echo -e "${YELLOW}已跳过无效端口: $port${NC}"
    fi
done

sudo ufw --force enable >/dev/null

echo -e "${CYAN}是否需要修改 SSH 端口？(y/n)${NC}"
read -rp "选择 [n]: " ssh_modify
if [[ "$ssh_modify" =~ ^[Yy]$ ]]; then
    read -rp "请输入新的 SSH 端口 (1025-65535): " new_ssh_port
    if [[ "$new_ssh_port" =~ ^[0-9]+$ ]] && [ "$new_ssh_port" -ge 1025 ] && [ "$new_ssh_port" -le 65535 ]; then
        backup="/etc/ssh/sshd_config.bak.$(date +%s)"
        sudo cp -a /etc/ssh/sshd_config "$backup"
        if sudo grep -qE '^[[:space:]]*#?[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
            sudo sed -i -E "s/^[[:space:]]*#?[[:space:]]*Port[[:space:]]+.*/Port $new_ssh_port/" /etc/ssh/sshd_config
        else
            echo "Port $new_ssh_port" | sudo tee -a /etc/ssh/sshd_config >/dev/null
        fi
        if sudo sshd -t; then
            sudo ufw allow "$new_ssh_port"/tcp >/dev/null
            sudo systemctl restart sshd
            echo -e "${GREEN}SSH 已切换到端口 $new_ssh_port。${NC}"
        else
            sudo cp -a "$backup" /etc/ssh/sshd_config
            echo -e "${RED}新的 SSH 配置校验失败，已恢复。${NC}" >&2
            exit 1
        fi
    else
        echo -e "${RED}端口输入无效，未修改 SSH 端口。${NC}"
    fi
fi

echo -e "${GREEN}UFW 防火墙配置完成。${NC}"
