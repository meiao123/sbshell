#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="/etc/sing-box/scripts"
TEMP_DIR=$(mktemp -d /tmp/sing-box-update.XXXXXX)
trap 'rm -rf "$TEMP_DIR"' EXIT
BASE_URL="https://raw.githubusercontent.com/qljsyph/sbshell/main/debian"
MENU_SCRIPT_URL="$BASE_URL/menu.sh"

SCRIPTS=(
    "check_environment.sh" "set_network.sh" "check_update.sh" "install_singbox.sh"
    "manual_input.sh" "manual_update.sh" "auto_update.sh" "configure_tproxy.sh"
    "configure_tun.sh" "start_singbox.sh" "stop_singbox.sh" "clean_nft.sh"
    "set_defaults.sh" "commands.sh" "switch_mode.sh" "manage_autostart.sh"
    "check_config.sh" "update_scripts.sh" "update_ui.sh" "delaytest.sh"
    "update_config.sh" "setup.sh" "ufw.sh" "kernel.sh" "optimize.sh" "menu.sh"
)

sudo install -d -o root -g root -m 0755 "$SCRIPT_DIR"

download_verified() {
    local name="$1" dest="$2"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 60 "$BASE_URL/$name" -o "$dest"
    [ -s "$dest" ] || { echo -e "${RED}$name 下载为空。${NC}" >&2; return 1; }
    bash -n "$dest"
}

LOCAL_VERSION=$(grep -m1 '^# 版本:' "$SCRIPT_DIR/menu.sh" 2>/dev/null | awk '{print $3}' || true)
download_verified menu.sh "$TEMP_DIR/menu.sh"
REMOTE_VERSION=$(grep -m1 '^# 版本:' "$TEMP_DIR/menu.sh" | awk '{print $3}' || true)
[ -n "$REMOTE_VERSION" ] || { echo -e "${RED}远程版本获取失败。${NC}" >&2; exit 1; }

echo -e "${CYAN}检测到的版本：本地版本 ${LOCAL_VERSION:-未知}，远程版本 $REMOTE_VERSION${NC}"
if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ]; then
    read -rp "脚本版本已是最新，是否强制更新？(y/n): " force_update
    [[ "$force_update" =~ ^[Yy]$ ]] || exit 0
fi

echo -e "${CYAN}正在下载并验证全部脚本...${NC}"
for script in "${SCRIPTS[@]}"; do
    download_verified "$script" "$TEMP_DIR/$script" || {
        echo -e "${RED}脚本 $script 校验失败，现有安装保持不变。${NC}" >&2
        exit 1
    }
done

# 所有文件下载并通过 shell 语法检查后才一次性安装，避免半更新状态。
for script in "${SCRIPTS[@]}"; do
    sudo install -o root -g root -m 0755 "$TEMP_DIR/$script" "$SCRIPT_DIR/$script"
done

# 防止旧版本遗留的脚本继续存在。
sudo find "$SCRIPT_DIR" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' | while IFS= read -r old; do
    case " ${SCRIPTS[*]} " in
        *" $old "*) ;;
        *) sudo rm -f -- "$SCRIPT_DIR/$old" ;;
    esac
done

sudo chown root:root "$SCRIPT_DIR"/*.sh
sudo chmod 0755 "$SCRIPT_DIR"/*.sh

echo -e "${GREEN}所有管理脚本已完成原子式验证和更新。${NC}"
