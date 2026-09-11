#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

if command -v sing-box >/dev/null 2>&1; then
    echo -e "${CYAN}sing-box 已安装，跳过安装步骤${NC}"
else
    sudo mkdir -p /etc/apt/keyrings
    sudo curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    sudo chmod 0644 /etc/apt/keyrings/sagernet.asc
    cat <<'EOF' | sudo tee /etc/apt/sources.list.d/sagernet.sources >/dev/null
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

    sudo apt-get update -qq
    while true; do
        read -rp "请选择安装版本(1: 稳定版, 2: 测试版): " version_choice
        case "$version_choice" in
            1) sudo apt-get install -yq sing-box; break ;;
            2) sudo apt-get install -yq sing-box-beta; break ;;
            *) echo -e "${RED}无效选择，请输入 1 或 2。${NC}" ;;
        esac
    done
fi

command -v sing-box >/dev/null 2>&1 || { echo -e "${RED}sing-box 安装失败。${NC}" >&2; exit 1; }

if ! id sing-box >/dev/null 2>&1; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin sing-box
fi
sudo install -d -o sing-box -g sing-box -m 0750 /var/lib/sing-box
sudo install -d -o root -g root -m 0755 /etc/sing-box
sudo install -d -o root -g root -m 0755 /etc/sing-box/scripts

# 使用 systemd drop-in，避免直接修改发行版提供的 unit 文件。
sudo install -d -o root -g root -m 0755 /etc/systemd/system/sing-box.service.d
cat <<'EOF' | sudo tee /etc/systemd/system/sing-box.service.d/10-sbshell.conf >/dev/null
[Service]
User=sing-box
StateDirectory=sing-box
EOF

# 校验 systemd 单元：应校验父 unit（sing-box.service）而不是 drop-in 文件本身，
# 旧写法在部分 systemd 版本上会以 "Failed to prepare filename ..." 直接失败并中止安装。
if command -v systemd-analyze >/dev/null 2>&1; then
    sudo systemd-analyze verify sing-box.service >/dev/null 2>&1 || {
        echo -e "${YELLOW}systemd 单元校验有告警，drop-in 已写入，继续安装。${NC}" >&2
    }
fi
sudo systemctl daemon-reload

# 模板配置的 cache_file 指向 /etc/sing-box/cache.db，而服务以 sing-box 用户运行、
# /etc/sing-box 属主是 root:root 0755：不预创建这个文件，缓存永远写不进去（日志报错、
# fakeip/选择器状态不持久）。这里预创建并交给 sing-box 用户。
if [ ! -e /etc/sing-box/cache.db ]; then
    sudo install -o sing-box -g sing-box -m 0600 /dev/null /etc/sing-box/cache.db
fi
if ! sudo systemctl restart sing-box; then
    echo -e "${RED}sing-box 服务启动失败，请检查 journalctl -u sing-box。${NC}" >&2
    exit 1
fi

echo -e "${CYAN}sing-box 服务已安全安装并重启。${NC}"
