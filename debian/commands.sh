#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
SCRIPT_DIR=/etc/sing-box/scripts

pause() { read -rp '按回车键返回二级菜单...' _; }
view_firewall_rules() { echo -e "${YELLOW}查看防火墙规则...${NC}"; nft list ruleset; pause; }
view_logs() { echo -e "${YELLOW}显示日志...${NC}"; journalctl -u sing-box --output cat -e; pause; }
live_logs() { echo -e "${YELLOW}实时日志...${NC}"; journalctl -u sing-box -f --output=cat; }
check_config() { echo -e "${YELLOW}检查配置文件...${NC}"; bash "$SCRIPT_DIR/check_config.sh"; pause; }
delaytest() { echo -e "${YELLOW}正在测试网络延迟...${NC}"; bash "$SCRIPT_DIR/delaytest.sh"; pause; }

setup_singbox_permissions() {
    echo -e "${YELLOW}正在设置 sing-box 权限与服务...${NC}"
    getent group sing-box >/dev/null 2>&1 || groupadd --system sing-box 2>/dev/null || true
    id sing-box >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin -g sing-box sing-box
    install -d -o sing-box -g sing-box -m 0750 /var/lib/sing-box
    install -d -o root -g root -m 0755 /etc/sing-box /etc/systemd/system/sing-box.service.d
    cat > /etc/systemd/system/sing-box.service.d/10-sbshell.conf <<'EOF'
[Service]
User=sing-box
StateDirectory=sing-box
EOF
    # 校验父 unit 而不是 drop-in 文件本身（旧写法在部分 systemd 版本上会直接失败）。
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify sing-box.service >/dev/null 2>&1 || {
            echo -e "${YELLOW}systemd 单元校验有告警，继续。${NC}" >&2
        }
    fi
    systemctl daemon-reload
    # 与 install_singbox.sh 一致：预创建 cache.db 并交给 sing-box 用户，
    # 否则 /etc/sing-box 不可写会导致缓存写入失败。
    if id sing-box >/dev/null 2>&1 && [ ! -e /etc/sing-box/cache.db ]; then
        install -o sing-box -g sing-box -m 0600 /dev/null /etc/sing-box/cache.db
    fi
    echo -e "${GREEN:-\033[0;32m}sing-box 权限与服务配置已完成。${NC}"
    pause
}

show_submenu() {
    echo -e "${CYAN}=========== 二级菜单选项 ===========${NC}"
    echo -e "${MAGENTA}1. 查看防火墙规则${NC}"
    echo -e "${MAGENTA}2. 显示日志${NC}"
    echo -e "${MAGENTA}3. 实时日志${NC}"
    echo -e "${MAGENTA}4. 检查配置文件${NC}"
    echo -e "${MAGENTA}5. 外网真实延迟测试${NC}"
    echo -e "${MAGENTA}6. 设置 sing-box 权限与服务${NC}"
    echo -e "${MAGENTA}0. 返回主菜单${NC}"
    echo -e "${CYAN}===================================${NC}"
}

while true; do
    show_submenu
    read -rp '请选择操作: ' choice
    case "$choice" in
        1) view_firewall_rules;; 2) view_logs;; 3) live_logs;; 4) check_config;;
        5) delaytest;; 6) setup_singbox_permissions;; 0) exit 0;;
        *) echo -e "${RED}无效的选择。${NC}";;
    esac
done
