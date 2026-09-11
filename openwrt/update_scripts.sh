#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR=/etc/sing-box/scripts
BASE_URL=https://raw.githubusercontent.com/meiao123/sbshell/main/openwrt
[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
mkdir -p "$SCRIPT_DIR"
chown root:root "$SCRIPT_DIR"; chmod 0755 "$SCRIPT_DIR"
SCRIPTS=(check_environment.sh install_singbox.sh manual_input.sh manual_update.sh auto_update.sh configure_tproxy.sh configure_tun.sh start_singbox.sh stop_singbox.sh clean_nft.sh set_defaults.sh commands.sh switch_mode.sh manage_autostart.sh check_config.sh update_scripts.sh update_ui.sh menu.sh)
tmpdir=$(mktemp -d /tmp/sbshell-update.XXXXXX); trap 'rm -rf "$tmpdir"' EXIT
for script in "${SCRIPTS[@]}"; do
    tmp="$tmpdir/$script"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$BASE_URL/$script" -o "$tmp" || exit 1
    bash -n "$tmp" || { echo "语法校验失败: $script" >&2; exit 1; }
done
for script in "${SCRIPTS[@]}"; do install -o root -g root -m 0755 "$tmpdir/$script" "$SCRIPT_DIR/$script"; done
echo 'OpenWrt 管理脚本更新完成。'
