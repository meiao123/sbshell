#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR=/etc/sing-box/scripts
BASE_REF=security-release-2026-09-11
BASE_URL="https://raw.githubusercontent.com/meiao123/sbshell/$BASE_REF/openwrt"
TMP_DIR=$(mktemp -d /tmp/sbshell-update.XXXXXX)
BACKUP_DIR=$(mktemp -d /tmp/sbshell-update-backup.XXXXXX)
trap 'rm -rf "$TMP_DIR" "$BACKUP_DIR"' EXIT
[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
install -d -m 0755 "$SCRIPT_DIR"
SCRIPTS=(check_environment.sh install_singbox.sh manual_input.sh manual_update.sh auto_update.sh configure_tproxy.sh configure_tun.sh start_singbox.sh stop_singbox.sh clean_nft.sh set_defaults.sh commands.sh switch_mode.sh manage_autostart.sh check_config.sh update_scripts.sh update_ui.sh menu.sh)
for script in "${SCRIPTS[@]}"; do
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$BASE_URL/$script" -o "$TMP_DIR/$script"
    [ -s "$TMP_DIR/$script" ] || exit 1
    bash -n "$TMP_DIR/$script"
    if head -n1 "$TMP_DIR/$script" | grep -q '^#!/bin/sh'; then sh -n "$TMP_DIR/$script"; fi
done
for script in "${SCRIPTS[@]}"; do
    if [ -f "$SCRIPT_DIR/$script" ]; then cp -a "$SCRIPT_DIR/$script" "$BACKUP_DIR/$script"; fi
done
restore() {
    local script
    for script in "${SCRIPTS[@]}"; do
        if [ -f "$BACKUP_DIR/$script" ]; then install -o root -g root -m 0755 "$BACKUP_DIR/$script" "$SCRIPT_DIR/$script"; else rm -f "$SCRIPT_DIR/$script"; fi
    done
}
for script in "${SCRIPTS[@]}"; do
    if ! install -o root -g root -m 0755 "$TMP_DIR/$script" "$SCRIPT_DIR/$script"; then restore; exit 1; fi
done
echo 'OpenWrt 管理脚本已完成审核发布引用下载、语法校验和事务式更新。'
