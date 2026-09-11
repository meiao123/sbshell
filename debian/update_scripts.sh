#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
SCRIPT_DIR=/etc/sing-box/scripts
BASE_URL=https://raw.githubusercontent.com/meiao123/sbshell/main/debian
TMP_DIR=$(mktemp -d /tmp/sing-box-update.XXXXXX)
BACKUP_DIR=$(mktemp -d /tmp/sing-box-update-backup.XXXXXX)
trap 'rm -rf "$TMP_DIR" "$BACKUP_DIR"' EXIT

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
install -d -o root -g root -m 0755 "$SCRIPT_DIR"

SCRIPTS=(
    check_environment.sh set_network.sh check_update.sh install_singbox.sh
    manual_input.sh manual_update.sh auto_update.sh configure_tproxy.sh
    configure_tun.sh start_singbox.sh stop_singbox.sh clean_nft.sh
    set_defaults.sh commands.sh switch_mode.sh manage_autostart.sh
    check_config.sh update_scripts.sh update_ui.sh delaytest.sh
    update_config.sh setup.sh ufw.sh kernel.sh optimize.sh menu.sh
)

download_verified() {
    local name="$1"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 60 "$BASE_URL/$name" -o "$TMP_DIR/$name"
    [ -s "$TMP_DIR/$name" ] || { echo -e "${RED}$name 下载为空。${NC}" >&2; return 1; }
    bash -n "$TMP_DIR/$name"
}

echo -e "${CYAN}正在下载并验证全部管理脚本...${NC}"
for script in "${SCRIPTS[@]}"; do
    download_verified "$script" || { echo -e "${RED}$script 校验失败，现有安装保持不变。${NC}" >&2; exit 1; }
done

# 保存当前版本；只有全部新文件通过校验后才进入替换阶段。
for script in "${SCRIPTS[@]}"; do
    [ -f "$SCRIPT_DIR/$script" ] && cp -a "$SCRIPT_DIR/$script" "$BACKUP_DIR/$script"
done

restore() {
    local script
    for script in "${SCRIPTS[@]}"; do
        if [ -f "$BACKUP_DIR/$script" ]; then
            install -o root -g root -m 0755 "$BACKUP_DIR/$script" "$SCRIPT_DIR/$script"
        else
            rm -f "$SCRIPT_DIR/$script"
        fi
    done
}

for script in "${SCRIPTS[@]}"; do
    if ! install -o root -g root -m 0755 "$TMP_DIR/$script" "$SCRIPT_DIR/$script"; then
        echo -e "${RED}安装 $script 失败，正在恢复旧版本。${NC}" >&2
        restore
        exit 1
    fi
done

find "$SCRIPT_DIR" -maxdepth 1 -type f -name '*.sh' -print0 | while IFS= read -r -d '' old; do
    name=$(basename "$old")
    case " ${SCRIPTS[*]} " in *" $name "*) ;; *) rm -f -- "$old" ;; esac
done

echo -e "${GREEN}全部管理脚本已完成下载、语法校验和事务式更新。${NC}"
