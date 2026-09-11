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

sudo systemd-analyze verify /etc/systemd/system/sing-box.service.d/10-sbshell.conf || {
    echo -e "${RED}systemd drop-in 校验失败。${NC}" >&2
    exit 1
}
sudo systemctl daemon-reload
if ! sudo systemctl restart sing-box; then
    echo -e "${RED}sing-box 服务启动失败，请检查 journalctl -u sing-box。${NC}" >&2
    exit 1
fi

echo -e "${CYAN}sing-box 服务已安全安装并重启。${NC}"
