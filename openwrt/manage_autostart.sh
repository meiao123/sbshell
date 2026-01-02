#!/bin/bash

# ================== 日志系统开始 ==================
LOG_FILE="/var/log/sbshell.log"

# 日志写入函数
# 用法: write_log "级别" "消息内容"
# 示例: write_log "INFO" "开始下载脚本..."
# 示例: write_log "ERROR" "下载失败，网络超时"
write_log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 写入日志文件
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # 如果是 ERROR，同时在屏幕红色输出
    if [ "$level" == "ERROR" ]; then
        echo -e "\033[0;31m[ERROR] $message\033[0m"
    elif [ "$level" == "INFO" ]; then
        # INFO 级别可选是否输出到屏幕，这里仅输出到文件，保持界面清爽
        :
    fi
}
# ================== 日志系统结束 ==================

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

echo -e "${GREEN}设置开机自启动...${NC}"
echo "请选择操作(1: 启用自启动, 2: 禁用自启动）"
read -rp "(1/2): " autostart_choice

apply_firewall() {
    MODE=$(grep -oP '(?<=^MODE=).*' /etc/sing-box/mode.conf)
    if [ "$MODE" = "TProxy" ]; then
        echo "应用 TProxy 模式下的防火墙规则..."
        bash /etc/sing-box/scripts/configure_tproxy.sh
    elif [ "$MODE" = "TUN" ]; then
        echo "应用 TUN 模式下的防火墙规则..."
        bash /etc/sing-box/scripts/configure_tun.sh
    else
        echo "无效的模式，跳过防火墙规则应用。"
        exit 1
    fi
}

case $autostart_choice in
    1)
        # 检查自启动是否已经开启
        if [ -f /etc/rc.d/S99sing-box ]; then
            echo -e "${GREEN}自启动已经开启，无需操作。${NC}"
            exit 0  # 返回主菜单
        fi

        echo -e "${GREEN}启用自启动...${NC}"

        # 启用并启动服务
        /etc/init.d/sing-box enable
        /etc/init.d/sing-box start
        cmd_status=$?

        if [ "$cmd_status" -eq 0 ]; then
            echo -e "${GREEN}自启动已成功启用。${NC}"
        else
            echo -e "${RED}启用自启动失败。${NC}"
        fi
        ;;
    2)
        # 检查自启动是否已经禁用
        if [ ! -f /etc/rc.d/S99sing-box ]; then
            echo -e "${GREEN}自启动已经禁用，无需操作。${NC}"
            exit 0  # 返回主菜单
        fi

        echo -e "${RED}禁用自启动...${NC}"
        
        # 禁用并停止服务
        /etc/init.d/sing-box disable
        cmd_status=$?

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

# 调用应用防火墙规则的函数
if [ "$1" = "apply_firewall" ]; then
    apply_firewall
fi