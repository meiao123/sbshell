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

# 检查 sing-box 是否已安装
if ! command -v sing-box &> /dev/null; then
    echo "请安装 sing-box 后再执行。"
    bash /etc/sing-box/scripts/install_singbox.sh
    exit 1
fi

# 确定文件存在
mkdir -p /etc/sing-box/
[ -f /etc/sing-box/mode.conf ] || touch /etc/sing-box/mode.conf
chmod 777 /etc/sing-box/mode.conf

echo "切换模式开始...请根据提示输入操作。"


while true; do
    # 选择模式
    read -rp "请选择模式(1: TProxy 模式, 2: TUN 模式): " mode_choice

    /etc/init.d/sing-box stop

    case $mode_choice in
        1)
            echo "MODE=TProxy" | tee /etc/sing-box/mode.conf > /dev/null
            echo -e "${GREEN}当前选择模式为:TProxy 模式${NC}"
            break
            ;;
        2)
            echo "MODE=TUN" | tee /etc/sing-box/mode.conf > /dev/null
            echo -e "${GREEN}当前选择模式为:TUN 模式${NC}"
            break
            ;;
        *)
            echo -e "${RED}无效的选择，请重新输入。${NC}"
            ;;
    esac
done
