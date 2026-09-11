#!/bin/bash
set -Eeuo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
SERVICE="/etc/systemd/system/nftables-singbox.service"
SCRIPT_DIR="/etc/sing-box/scripts"
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

apply_firewall() {
    local mode
    mode=$(awk -F= '$1 == "MODE" {print $2; exit}' /etc/sing-box/mode.conf 2>/dev/null || true)
    case "$mode" in
        TProxy) exec "$SCRIPT_DIR/configure_tproxy.sh" ;;
        TUN) exec "$SCRIPT_DIR/configure_tun.sh" ;;
        *) echo "无效的模式: $mode" >&2; return 1 ;;
    esac
}

if [[ "${1:-}" == "apply_firewall" ]]; then
    apply_firewall
    exit $?
fi

read -rp "请选择操作(1: 启用自启动, 2: 禁用自启动): " choice
case "$choice" in
1)
    cat > "$SERVICE" <<EOF
[Unit]
Description=Apply sing-box firewall rules
After=network-online.target
Wants=network-online.target
Before=sing-box.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/manage_autostart.sh apply_firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable nftables-singbox.service
    systemctl enable sing-box.service
    if ! systemctl start nftables-singbox.service; then
        systemctl disable nftables-singbox.service >/dev/null 2>&1 || true
        rm -f "$SERVICE"
        systemctl daemon-reload
        echo -e "${RED}防火墙规则应用失败，未启用自启动。${NC}"
        exit 1
    fi
    systemctl restart sing-box
    echo -e "${GREEN}自启动已成功启用。${NC}"
    ;;
2)
    systemctl disable nftables-singbox.service >/dev/null 2>&1 || true
    systemctl disable sing-box.service >/dev/null 2>&1 || true
    systemctl stop nftables-singbox.service >/dev/null 2>&1 || true
    rm -f "$SERVICE"
    systemctl daemon-reload
    echo -e "${GREEN}自启动已成功禁用。${NC}"
    ;;
*) echo -e "${RED}无效的选择。${NC}"; exit 1 ;;
esac
