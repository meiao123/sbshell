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

write_log "INFO" "用户请求启动 sing-box..."

# 定义颜色
CYAN='\033[0;36m'
GREEN='\033[0;32m'
MAGENTA='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

# 检查当前模式
check_mode() {
    if nft list chain inet sing-box prerouting_tproxy &>/dev/null || nft list chain inet sing-box output_tproxy &>/dev/null; then
        echo "TProxy 模式"
    else
        echo "TUN 模式"
    fi
}

# 启动 sing-box 服务
start_singbox() {
    echo -e "${CYAN}检测是否处于非代理环境...${NC}"
    # 使用 -w %{http_code} 获取状态码
    STATUS_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://www.google.com")

    if [ "$STATUS_CODE" -eq 200 ]; then
        echo -e "${RED}当前网络处于代理环境, 启动 sing-box 建议直连!${NC}"
    else
        echo -e "${CYAN}当前网络环境非代理网络，可以启动 sing-box。${NC}"
    fi

    echo -e "${CYAN}正在清理旧进程并启动...${NC}"
    
    # 1. 暴力清理旧进程，防止端口占用
    killall -9 sing-box 2>/dev/null
    sleep 1
    
    # 2. 启动服务
    /etc/init.d/sing-box enable
    /etc/init.d/sing-box start

    echo -e "${CYAN}正在等待进程启动 (3秒)...${NC}"
    sleep 3

    # 3. 获取 PID (一次性获取)
    local PID
    PID=$(pgrep -x "sing-box")

    # 4. 判断逻辑
    if [ -n "$PID" ]; then
        # =========== 成功分支 ===========
        echo -e "${GREEN}★ sing-box 启动成功！★${NC}"
        echo -e "${GREEN}进程 PID: ${PID}${NC}"
        
        # 记录日志
        write_log "INFO" "启动成功，进程PID: ${PID}"
        
        # 显示模式
        mode=$(check_mode)
        echo -e "${MAGENTA}当前运行模式: ${mode}${NC}"
    else
        # =========== 失败分支 ===========
        echo -e "${RED}启动失败！未检测到运行进程。${NC}"
        write_log "ERROR" "启动失败，进程未找到。"
        
        # 只有在这里才会打印系统日志
        echo -e "${YELLOW}================ 系统报错日志 (最后 15 行) ================${NC}"
        # 过滤 sing-box 或 procd (守护进程) 的日志，能看到更全的报错
        logread | grep -E "sing-box|procd|netifd" | tail -n 15
        echo -e "${YELLOW}==========================================================${NC}"
    fi
}

# 提示用户确认是否启动
read -rp "是否启动 sing-box?(y/n): " confirm_start
if [[ "$confirm_start" =~ ^[Yy]$ ]]; then
    start_singbox
else
    echo -e "${CYAN}已取消启动 sing-box。${NC}"
    exit 0
fi
