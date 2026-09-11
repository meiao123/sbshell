#!/bin/bash
set -Eeuo pipefail
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
SCRIPT_DIR=/etc/sing-box/scripts
INITIALIZED_FILE="$SCRIPT_DIR/.initialized"
ROLE_FILE="$SCRIPT_DIR/.role"
BASE_URL=https://raw.githubusercontent.com/meiao123/sbshell/main/openwrt
SCRIPTS=(check_environment.sh install_singbox.sh manual_input.sh manual_update.sh auto_update.sh configure_tproxy.sh configure_tun.sh start_singbox.sh stop_singbox.sh clean_nft.sh set_defaults.sh commands.sh switch_mode.sh manage_autostart.sh check_config.sh update_scripts.sh update_ui.sh menu.sh)
mkdir -p "$SCRIPT_DIR"; chown root:root "$SCRIPT_DIR"; chmod 0755 "$SCRIPT_DIR"

update_scripts(){
 tmp=$(mktemp -d /tmp/sbshell-openwrt.XXXXXX); trap 'rm -rf "$tmp"' RETURN
 for s in "${SCRIPTS[@]}"; do curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$BASE_URL/$s" -o "$tmp/$s" || return 1; bash -n "$tmp/$s" || return 1; done
 for s in "${SCRIPTS[@]}"; do install -o root -g root -m 0755 "$tmp/$s" "$SCRIPT_DIR/$s"; done
}
run(){ bash "$SCRIPT_DIR/$1"; }
initialize(){ update_scripts || { echo -e "${RED}脚本更新失败。${NC}"; return 1; }; run check_environment.sh; run install_singbox.sh; run switch_mode.sh; run manual_input.sh; run start_singbox.sh; touch "$INITIALIZED_FILE"; chmod 0644 "$INITIALIZED_FILE"; }

if [ ! -f "$INITIALIZED_FILE" ]; then
 echo -e "${CYAN}回车进入初始化，输入 skip 跳过：${NC}"; read -r choice
 if [[ ! "$choice" =~ ^[Ss]kip$ ]]; then initialize || exit 1; else update_scripts || exit 1; fi
else
 [ -f "$SCRIPT_DIR/menu.sh" ] || update_scripts || exit 1
fi

while true; do
 echo -e "${CYAN}=========== Sbshell OpenWrt 管理菜单 ===========${NC}"
 echo '1. TProxy/TUN 模式切换'; echo '2. 手动更新配置'; echo '3. 自动更新配置'; echo '4. 启动 sing-box'; echo '5. 停止 sing-box'; echo '6. 默认参数设置'; echo '7. 设置自启动'; echo '8. 常用命令'; echo '9. 更新脚本'; echo '10. 更新控制面板'; echo '0. 退出'
 read -rp '请选择操作: ' choice
 case "$choice" in
 1) run switch_mode.sh; run manual_input.sh; run start_singbox.sh;;
 2) run manual_update.sh;;
 3) run auto_update.sh;;
 4) run start_singbox.sh;;
 5) run stop_singbox.sh;;
 6) run set_defaults.sh;;
 7) run manage_autostart.sh;;
 8) run commands.sh;;
 9) run update_scripts.sh;;
 10) run update_ui.sh;;
 0) exit 0;;
 *) echo -e "${RED}无效选择。${NC}";;
 esac
done
