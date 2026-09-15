#!/bin/bash
set -Eeuo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
SCRIPT_DIR=/etc/sing-box/scripts
BASE_URL="https://raw.githubusercontent.com/meiao123/sbshell/main/debian"
# 更新源固定为 main（见 README「代码来源」与 docs/security-hardening.md）：
# 已移除 RELEASE 发布声明与不可变 SHA 固定机制。
# 先提权再做任何事：`exec` 不会触发 EXIT trap，先建临时目录会在非 root 调用时泄漏
# （并且提权后的实例还会再建一份）。
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
# 提权之后、真正下载之前准备临时目录。
TMP_DIR=$(mktemp -d /tmp/sing-box-update.XXXXXX) || exit 1
BACKUP_DIR=$(mktemp -d /tmp/sing-box-update-backup.XXXXXX) || { rm -rf "$TMP_DIR"; exit 1; }
trap 'rm -rf "$TMP_DIR" "$BACKUP_DIR"' EXIT
install -d -o root -g root -m 0755 "$SCRIPT_DIR"
SCRIPTS=(check_environment.sh set_network.sh check_update.sh install_singbox.sh manual_input.sh manual_update.sh auto_update.sh configure_tproxy.sh configure_tun.sh start_singbox.sh stop_singbox.sh clean_nft.sh set_defaults.sh commands.sh switch_mode.sh manage_autostart.sh check_config.sh update_ui.sh delaytest.sh update_config.sh setup.sh ufw.sh kernel.sh optimize.sh gen_server_config.sh menu.sh)
download_verified() { local name="$1"; curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$BASE_URL/$name" -o "$TMP_DIR/$name"; [ -s "$TMP_DIR/$name" ] || return 1; bash -n "$TMP_DIR/$name"; if head -n1 "$TMP_DIR/$name" | grep -q '^#!/bin/sh'; then sh -n "$TMP_DIR/$name"; fi; }
for script in "${SCRIPTS[@]}"; do download_verified "$script" || { echo -e "${RED}$script 校验失败，现有安装保持不变。${NC}" >&2; exit 1; }; done
for script in "${SCRIPTS[@]}"; do if [ -f "$SCRIPT_DIR/$script" ]; then cp -a "$SCRIPT_DIR/$script" "$BACKUP_DIR/$script"; fi; done
restore() { local script; for script in "${SCRIPTS[@]}"; do if [ -f "$BACKUP_DIR/$script" ]; then install -o root -g root -m 0755 "$BACKUP_DIR/$script" "$SCRIPT_DIR/$script"; else rm -f "$SCRIPT_DIR/$script"; fi; done; }
for script in "${SCRIPTS[@]}"; do if ! install -o root -g root -m 0755 "$TMP_DIR/$script" "$SCRIPT_DIR/$script"; then restore; exit 1; fi; done
echo -e "${GREEN}全部管理脚本已完成审核发布引用下载、语法校验和事务式更新。${NC}"
