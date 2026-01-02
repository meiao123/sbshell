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

    echo -e "${CYAN}正在等待进程启动 (最大等待 10秒)...${NC}"

    # ================== 改进后的检测逻辑 ==================
    local RETRY=0
    local MAX_RETRY=10
    local PID=""
    
    # 1. 动态轮询：等待进程出现
    while [ $RETRY -lt $MAX_RETRY ]; do
        # 尝试获取 PID (兼容性写法)
        PID=$(pgrep -f "sing-box" | grep -v "bash" | head -n 1)
        
        if [ -n "$PID" ]; then
            break
        fi
        
        echo -n "."
        sleep 1
        ((RETRY++))
    done
    echo "" # 换行

    # 2. 初步判断
    if [ -z "$PID" ]; then
        echo -e "${RED}启动超时！在 $MAX_RETRY 秒内未检测到进程。${NC}"
        # 打印日志逻辑...
        echo -e "${YELLOW}================ 系统报错日志 ================${NC}"
        logread | grep -E "sing-box|procd|netifd" | tail -n 15
        return 1
    fi

    # 3. 关键步骤：二次核验 (防止“假启动”)
    # 很多时候进程起来了，但因为配置错误在 1-2 秒后崩溃
    echo -e "${CYAN}检测到进程 (PID: $PID)，正在进行稳定性校验...${NC}"
    sleep 3 

    # 再次检查这个 PID 是否还活着
    if [ -d "/proc/$PID" ]; then
        # =========== 最终成功 ===========
        echo -e "${GREEN}★ sing-box 启动成功且运行稳定！★${NC}"
        echo -e "${GREEN}进程 PID: ${PID}${NC}"
        
        write_log "INFO" "启动成功，进程PID: ${PID}"
        
        mode=$(check_mode)
        echo -e "${MAGENTA}当前运行模式: ${mode}${NC}"
    else
        # =========== 启动后立即崩溃 ===========
        echo -e "${RED}检测到服务启动后立即崩溃！${NC}"
        echo -e "${RED}这通常是 配置文件错误 或 端口冲突 导致的。${NC}"
        write_log "ERROR" "启动不稳定，进程启动后消失。"
        
        echo -e "${YELLOW}================ 系统报错日志 (崩溃原因) ================${NC}"
        logread | grep -E "sing-box|procd|netifd" | tail -n 15
        echo -e "${YELLOW}======================================================${NC}"
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
