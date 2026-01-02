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
CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m' # 无颜色

# 脚本下载目录
SCRIPT_DIR="/etc/sing-box/scripts"

# 停止 sing-box 服务
stop_singbox() {
    echo -e "${CYAN}正在停止 sing-box 服务...${NC}"
    /etc/init.d/sing-box stop
    result=$?
    if [ $result -ne 0 ]; then
        echo -e "${CYAN}停止 sing-box 服务失败，返回码: $result${NC}"
    else
        echo -e "${GREEN}sing-box 已成功停止。${NC}"
    fi

    read -rp "是否清理防火墙规则？(y/n): " confirm_cleanup
    if [[ "$confirm_cleanup" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}执行清理防火墙规则...${NC}"
        bash "$SCRIPT_DIR/clean_nft.sh"
        echo -e "${GREEN}防火墙规则清理完毕${NC}"
    else
        echo -e "${CYAN}已取消清理防火墙规则。${NC}"
    fi
}

read -rp "是否停止 sing-box?(y/n): " confirm_stop
if [[ "$confirm_stop" =~ ^[Yy]$ ]]; then
    stop_singbox
else
    echo -e "${CYAN}已取消停止 sing-box。${NC}"
    exit 0
fi
