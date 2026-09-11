#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

# 本脚本以 root 运行（菜单/快捷方式已经是 root）；显式检查以便独立执行时也安全，
# 不再到处写 `sudo`：最小 Debian 安装与容器里可能没有 sudo。
[ "$(id -u)" -eq 0 ] || { [ -x "$(command -v sudo 2>/dev/null)" ] && exec sudo bash "$0" "$@" || { echo -e "${RED}请以 root 运行。${NC}" >&2; exit 1; }; }

if command -v sing-box >/dev/null 2>&1; then
    echo -e "${CYAN}sing-box 已安装，跳过安装步骤${NC}"
else
    mkdir -p /etc/apt/keyrings
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    chmod 0644 /etc/apt/keyrings/sagernet.asc
    cat <<'EOF' > /etc/apt/sources.list.d/sagernet.sources
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

    apt-get update -qq
    while true; do
        read -rp "请选择安装版本(1: 稳定版, 2: 测试版): " version_choice || { echo '无法读取输入。' >&2; exit 1; }
        case "$version_choice" in
            1) apt-get install -yq sing-box; break ;;
            2) apt-get install -yq sing-box-beta; break ;;
            *) echo -e "${RED}无效选择，请输入 1 或 2。${NC}" ;;
        esac
    done
fi

command -v sing-box >/dev/null 2>&1 || { echo -e "${RED}sing-box 安装失败。${NC}" >&2; exit 1; }

if ! id sing-box >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin sing-box
fi
install -d -o sing-box -g sing-box -m 0750 /var/lib/sing-box
install -d -o root -g root -m 0755 /etc/sing-box
install -d -o root -g root -m 0755 /etc/sing-box/scripts

# 使用 systemd drop-in，避免直接修改发行版提供的 unit 文件。
install -d -o root -g root -m 0755 /etc/systemd/system/sing-box.service.d
cat <<'EOF' > /etc/systemd/system/sing-box.service.d/10-sbshell.conf
[Service]
User=sing-box
StateDirectory=sing-box
EOF

# 校验 systemd 单元：应校验父 unit（sing-box.service）而不是 drop-in 文件本身，
# 旧写法在部分 systemd 版本上会以 "Failed to prepare filename ..." 直接失败并中止安装。
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify sing-box.service >/dev/null 2>&1 || {
        echo -e "${YELLOW:-}systemd 单元校验有告警，drop-in 已写入，继续安装。${NC}" >&2
    }
fi
systemctl daemon-reload

# 模板配置的 cache_file 指向 /etc/sing-box/cache.db，而服务以 sing-box 用户运行、
# /etc/sing-box 属主是 root:root 0755：不预创建这个文件，缓存永远写不进去（日志报错、
# fakeip/选择器状态不持久）。这里预创建并交给 sing-box 用户。
if [ ! -e /etc/sing-box/cache.db ]; then
    install -o sing-box -g sing-box -m 0600 /dev/null /etc/sing-box/cache.db
fi

if ! systemctl restart sing-box; then
    echo -e "${RED}sing-box 服务启动失败，请检查 journalctl -u sing-box。${NC}" >&2
    exit 1
fi

echo -e "${CYAN}sing-box 服务已安全安装并重启。${NC}"
