#!/bin/bash

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

SCRIPT_DIR=/etc/sing-box/scripts
INIT_SCRIPT=/etc/init.d/sbshell-firewall

# 应用当前模式的防火墙规则。
# 注意：这个分支必须在交互式 read 之前处理，否则任何以参数方式调用（开机、init 脚本）
# 都会先卡在输入上。
apply_firewall() {
    local mode
    # busybox grep 不支持 -oP（PCRE），这里用 sed，与其它脚本保持一致。
    mode=$(sed -n 's/^MODE=//p' /etc/sing-box/mode.conf 2>/dev/null | head -n1)
    case "$mode" in
        TProxy)
            echo "应用 TProxy 模式下的防火墙规则..."
            bash "$SCRIPT_DIR/configure_tproxy.sh"
            ;;
        TUN)
            echo "应用 TUN 模式下的防火墙规则..."
            bash "$SCRIPT_DIR/configure_tun.sh"
            ;;
        *)
            echo -e "${RED}无效的模式: ${mode:-未设置}${NC}" >&2
            return 1
            ;;
    esac
}

if [ "${1:-}" = "apply_firewall" ]; then
    apply_firewall
    exit $?
fi

# nftables 规则不跨重启保留，所以“开机自启动”必须包含一个重新下发规则的 init 脚本，
# 否则重启后 sing-box 在运行、但 TProxy/TUN 规则全部丢失（代理静默失效）。
write_firewall_init() {
    cat > "$INIT_SCRIPT" <<EOF
#!/bin/sh /etc/rc.common
# Sbshell: 开机重新下发 TProxy/TUN nftables 规则（nft 规则不持久，必须每次开机重建）
START=40
STOP=10

start() {
\t$SCRIPT_DIR/manage_autostart.sh apply_firewall
}

stop() {
\treturn 0
}

boot() {
\tstart "\$@"
}
EOF
    chmod 0755 "$INIT_SCRIPT"
    chown root:root "$INIT_SCRIPT"
}

echo -e "${GREEN}设置开机自启动...${NC}"
echo "请选择操作(1: 启用自启动, 2: 禁用自启动）"
read -rp "(1/2): " autostart_choice

case $autostart_choice in
    1)
        write_firewall_init

        # 检查自启动是否已经开启
        if [ -f /etc/rc.d/S99sing-box ] && [ -f /etc/rc.d/S40sbshell-firewall ]; then
            echo -e "${GREEN}自启动已经开启，无需操作。${NC}"
            exit 0
        fi

        echo -e "${GREEN}启用自启动...${NC}"

        # 如果 sing-box 当前已经运行，说明当前会话的防火墙已由启动流程应用。
        # 此时不要再次调用 configure_tun/configure_tproxy，否则它们会把运行中的 nft 表视为外部表而拒绝覆盖。
        if pidof sing-box >/dev/null 2>&1; then
            echo -e "${GREEN}sing-box 已在运行，跳过当前防火墙重载。${NC}"
        elif ! "$INIT_SCRIPT" start; then
            echo -e "${RED}防火墙规则应用失败，未启用自启动。${NC}" >&2
            exit 1
        fi
        if ! /etc/init.d/sbshell-firewall enable; then
            echo -e "${RED}注册开机防火墙脚本失败，未启用自启动。${NC}" >&2
            exit 1
        fi

        /etc/init.d/sing-box enable
        /etc/init.d/sing-box start
        cmd_status=$?

        if [ "$cmd_status" -eq 0 ]; then
            echo -e "${GREEN}自启动已成功启用（含开机防火墙规则恢复）。${NC}"
        else
            echo -e "${RED}启用自启动失败。${NC}"
        fi
        ;;
    2)
        # 检查自启动是否已经禁用
        if [ ! -f /etc/rc.d/S99sing-box ] && [ ! -f /etc/rc.d/S40sbshell-firewall ]; then
            echo -e "${GREEN}自启动已经禁用，无需操作。${NC}"
            exit 0
        fi

        echo -e "${RED}禁用自启动...${NC}"

        # 禁用并停止服务
        /etc/init.d/sing-box disable
        cmd_status=$?
        if [ -f "$INIT_SCRIPT" ]; then
            /etc/init.d/sbshell-firewall disable >/dev/null 2>&1 || true
        fi

        if [ "$cmd_status" -eq 0 ]; then
            echo -e "${GREEN}自启动已成功禁用。${NC}"
        else
            echo -e "${RED}禁用自启动失败。${NC}"
        fi
        ;;
    *)
        echo -e "${RED}无效的选择${NC}"
        ;;
esac
