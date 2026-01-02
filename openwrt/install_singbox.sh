#!/bin/bash

# 定义颜色
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

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

# ----------------------------------------------------------------
# 辅助函数：手动从 GitHub 下载安装 (B计划)
# ----------------------------------------------------------------
install_from_github() {
    echo -e "${YELLOW}opkg 安装失败，尝试从 GitHub 手动下载最新版...${NC}"
    write_log "INFO" "切换至手动安装模式..."

    # 1. 检测 CPU 架构
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  DOWNLOAD_ARCH="amd64" ;;
        aarch64) DOWNLOAD_ARCH="arm64" ;;
        armv7l)  DOWNLOAD_ARCH="armv7" ;;
        *)       
            echo -e "${RED}不支持的架构: $ARCH${NC}"
            write_log "ERROR" "架构不支持: $ARCH"
            return 1 
            ;;
    esac

    # 2. 获取最新版本号 (如果获取失败则使用硬编码版本)
    VERSION=$(curl -sL https://ghfast.top/https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [ -z "$VERSION" ]; then
        VERSION="1.12.1" # 备用版本
    fi
    
    echo -e "${CYAN}检测到架构: ${DOWNLOAD_ARCH}, 目标版本: ${VERSION}${NC}"

    # 3. 构造下载链接 (使用 ghfast 加速)
    # 文件名示例: sing-box-1.10.1-linux-amd64.tar.gz
    FILE_NAME="sing-box-${VERSION}-linux-${DOWNLOAD_ARCH}.tar.gz"
    DOWNLOAD_URL="https://ghfast.top/https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/${FILE_NAME}"

    # 4. 下载
    echo -e "${CYAN}正在下载: ${FILE_NAME}...${NC}"
    curl -L -o "/tmp/${FILE_NAME}" "$DOWNLOAD_URL"
    
    if [ ! -s "/tmp/${FILE_NAME}" ]; then
        echo -e "${RED}下载失败！文件为空。${NC}"
        return 1
    fi

    # 5. 解压并安装
    echo -e "${CYAN}正在解压安装...${NC}"
    cd /tmp
    tar -xzf "$FILE_NAME"
    
    # 提取核心文件 (解压出来的目录名通常也是 sing-box-版本-架构)
    EXTRACTED_DIR="sing-box-${VERSION}-linux-${DOWNLOAD_ARCH}"
    if [ -d "$EXTRACTED_DIR" ]; then
        mv "$EXTRACTED_DIR/sing-box" /usr/bin/sing-box
        chmod +x /usr/bin/sing-box
        rm -rf "$FILE_NAME" "$EXTRACTED_DIR"
        echo -e "${CYAN}手动安装成功！${NC}"
        return 0
    else
        echo -e "${RED}解压失败，找不到目录: $EXTRACTED_DIR${NC}"
        return 1
    fi
}

# ----------------------------------------------------------------
# 主逻辑
# ----------------------------------------------------------------

echo -e "${CYAN}开始检查并安装 sing-box 环境...${NC}"
write_log "INFO" "开始安装 sing-box..."

# 1. 尝试使用 opkg 安装依赖 (内核模块必须用 opkg 装)
opkg update >/dev/null 2>&1
echo -e "${CYAN}正在安装依赖 (kmod-nft-tproxy, ca-bundle)...${NC}"
opkg install kmod-nft-tproxy ca-bundle ca-certificates >/dev/null 2>&1

# 2. 尝试安装 sing-box
if command -v sing-box &> /dev/null; then
    echo -e "${CYAN}sing-box 已存在，跳过安装。${NC}"
else
    echo -e "${CYAN}尝试通过 opkg 安装 sing-box...${NC}"
    opkg install sing-box >/dev/null 2>&1
    
    # 如果 opkg 安装失败 (找不到命令)，则执行 B 计划
    if ! command -v sing-box &> /dev/null; then
        install_from_github
        if [ $? -ne 0 ]; then
            echo -e "${RED}严重错误：sing-box 安装彻底失败！${NC}"
            write_log "ERROR" "opkg 和手动安装均失败。"
            exit 1
        fi
    fi
fi

echo -e "${CYAN}核心程序检查通过，正在部署启动服务...${NC}"

# 2. 根治核心：直接覆盖写入启动脚本 (使用 > 而不是 >>)
# 这一步保证了无论脚本运行多少次，/etc/init.d/sing-box 永远是干净、正确的
cat << 'EOF' > /etc/init.d/sing-box
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

# 【修复关键点1】声明 load_firewall 是一个合法的额外命令
# 如果不加这行，调用 /etc/init.d/sing-box load_firewall 会报错 Syntax error
EXTRA_COMMANDS="load_firewall"

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
    ( sleep 3 && /etc/init.d/sing-box load_firewall >/dev/null 2>&1 ) &
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

echo -e "${CYAN}sing-box 安装完成 (等待配置后启动)${NC}"
