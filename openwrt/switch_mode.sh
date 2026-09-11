#!/bin/bash
set -Eeuo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
MODE_FILE=/etc/sing-box/mode.conf

if ! command -v sing-box >/dev/null 2>&1; then
    echo "请安装 sing-box 后再执行。"
    bash /etc/sing-box/scripts/install_singbox.sh
    exit 1
fi

install -d -o root -g root -m 0755 /etc/sing-box
if [ -e "$MODE_FILE" ] && [ ! -f "$MODE_FILE" ]; then
    echo -e "${RED}mode.conf 不是普通文件，拒绝修改。${NC}" >&2
    exit 1
fi
[ -f "$MODE_FILE" ] || install -o root -g root -m 0644 /dev/null "$MODE_FILE"
chown root:root "$MODE_FILE"
chmod 0644 "$MODE_FILE"

echo "切换模式开始...请根据提示输入操作。"
while true; do
    read -rp "请选择模式(1: TProxy 模式, 2: TUN 模式): " mode_choice

    /etc/init.d/sing-box stop

    case "$mode_choice" in
        1)
            printf 'MODE=TProxy\n' > "$MODE_FILE"
            chmod 0644 "$MODE_FILE"
            echo -e "${GREEN}当前选择模式为:TProxy 模式${NC}"
            break
            ;;
        2)
            printf 'MODE=TUN\n' > "$MODE_FILE"
            chmod 0644 "$MODE_FILE"
            echo -e "${GREEN}当前选择模式为:TUN 模式${NC}"
            break
            ;;
        *)
            echo -e "${RED}无效的选择，请重新输入。${NC}"
            ;;
    esac
done
