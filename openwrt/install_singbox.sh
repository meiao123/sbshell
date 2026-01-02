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

write_log "INFO" "开始执行 sing-box 安装脚本..."

# 定义颜色
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

if command -v sing-box &> /dev/null; then
    echo -e "${CYAN}sing-box 已安装，跳过安装步骤${NC}"
else
    echo "正在更新包列表并安装 sing-box,请稍候..."
    opkg update >/dev/null 2>&1
    opkg install kmod-nft-tproxy ca-bundle ca-certificates >/dev/null 2>&1
    opkg install sing-box >/dev/null 2>&1

    # 捕获错误输出到变量
    INSTALL_LOG=$(opkg install kmod-nft-tproxy sing-box ca-bundle 2>&1)

    if command -v sing-box &> /dev/null; then
        echo -e "${CYAN}sing-box 安装成功${NC}"
    else
        echo -e "${RED}sing-box 安装失败，请检查日志或网络配置${NC}"
        exit 1
    fi
fi

echo -e "${CYAN}核心程序检查通过，正在部署启动服务...${NC}"

# 2. 根治核心：直接覆盖写入启动脚本 (使用 > 而不是 >>)
# 这一步保证了无论脚本运行多少次，/etc/init.d/sing-box 永远是干净、正确的
cat << 'EOF' > /etc/init.d/sing-box
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

PROG=/usr/bin/sing-box
CONF=/etc/sing-box/config.json

start_service() {
    # 启动前检查配置文件是否存在
    if [ ! -f "$CONF" ]; then
        return 1
    fi

    procd_open_instance
    procd_set_param command "$PROG" run -c "$CONF"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    # 调大文件描述符限制，防止连接数过多报错
    procd_set_param limits nofile="65535 65535"
    procd_close_instance
    
    # 简单的延时，确保进程起来后再加载防火墙规则
    # 注意：更优雅的方式是放到 firewall include 中，但为了兼容你的旧脚本逻辑，保留此处
    ( sleep 3 && /etc/init.d/sing-box load_firewall ) &
}

# 自定义函数：加载防火墙规则
load_firewall() {
    # 读取模式配置，默认为 TUN
    MODE="TUN"
    if [ -f /etc/sing-box/mode.conf ]; then
        MODE=$(grep -oE '^MODE=.*' /etc/sing-box/mode.conf | cut -d'=' -f2)
    fi

    # 根据模式调用对应的脚本
    if [ "$MODE" = "TProxy" ]; then
        [ -f /etc/sing-box/scripts/configure_tproxy.sh ] && /etc/sing-box/scripts/configure_tproxy.sh
    elif [ "$MODE" = "TUN" ]; then
        [ -f /etc/sing-box/scripts/configure_tun.sh ] && /etc/sing-box/scripts/configure_tun.sh
    fi
}

stop_service() {
    # 停止时尝试清理 nftables 规则
    [ -f /etc/sing-box/scripts/clean_nft.sh ] && /etc/sing-box/scripts/clean_nft.sh
}

restart() {
    stop
    start
}
EOF

if [ $? -eq 0 ]; then
    write_log "INFO" "启动文件写入成功"
else
    write_log "ERROR" "启动文件写入失败！权限不足？"
fi

# 3. 赋予权限并启用
chmod +x /etc/init.d/sing-box
/etc/init.d/sing-box enable

# 4. 尝试启动
/etc/init.d/sing-box restart

echo -e "${CYAN}sing-box 安装与服务配置完成！${NC}"
