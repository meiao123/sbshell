#!/bin/bash

# 定义颜色
CYAN='\033[0;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# 卸载确认
echo -e "${RED}================= ⚠️  卸载警告 ⚠️  =================${NC}"
echo -e "${RED}此操作将执行以下清理：${NC}"
echo -e "1. 停止并禁用 sing-box 服务"
echo -e "2. 删除 sing-box 核心程序"
echo -e "3. 删除所有配置文件和脚本 (/etc/sing-box)"
echo -e "4. 删除系统服务文件 (/etc/init.d/sing-box)"
echo -e "5. 清理全局快捷命令 (sb)"
echo -e "${RED}==================================================${NC}"

read -e -p "你确定要彻底卸载吗? (输入 y 确认): " confirm

if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}正在停止服务...${NC}"
    /etc/init.d/sing-box stop 2>/dev/null
    /etc/init.d/sing-box disable 2>/dev/null

    echo -e "${CYAN}正在删除文件...${NC}"
    # 删除服务文件
    rm -f /etc/init.d/sing-box
    # 删除核心
    rm -f /usr/bin/sing-box
    # 删除快捷方式
    rm -f /usr/bin/sb
    # 删除日志
    rm -f /var/log/sbshell.log

    # 备份配置文件（可选，这里直接删除）
    # 如果想保留配置，把下面这行注释掉
    rm -rf /etc/sing-box

    # 清理 .bashrc 中的别名
    sed -i '/alias sb=/d' ~/.bashrc
    unalias sb 2>/dev/null

    echo -e "${GREEN}卸载完成！${NC}"
    exit 0
else
    echo -e "${GREEN}已取消卸载。${NC}"
    exit 0
fi

chmod +x /etc/sing-box/scripts/uninstall.sh