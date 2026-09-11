#!/bin/bash
set -Eeuo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
MODE_FILE=/etc/sing-box/mode.conf
SCRIPT_DIR=/etc/sing-box/scripts

# 与其它脚本一致：已经是 root 就直接干活，不再依赖系统里一定有 sudo
# （Debian/OpenWrt 最小安装、容器里常常没有 sudo，旧代码的 `sudo xxx` 会 command not found
#  并且因为缺少 set -e 而静默继续，导致 mode.conf 根本没写成功）
[ "$(id -u)" -eq 0 ] || { [ -x "$(command -v sudo 2>/dev/null)" ] && exec sudo bash "$0" "$@" || { echo -e "${RED}请以 root 运行。${NC}" >&2; exit 1; }; }

if ! command -v sing-box >/dev/null 2>&1; then
    echo "请安装 sing-box 后再执行。"
    bash "$SCRIPT_DIR/install_singbox.sh"
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
OLD_MODE=$(sed -n 's/^MODE=//p' "$MODE_FILE" 2>/dev/null | head -n1)
case "$OLD_MODE" in TProxy|TUN) ;; *) OLD_MODE='' ;; esac

while true; do
    read -rp "请选择模式(1: TProxy 模式, 2: TUN 模式): " mode_choice || { echo '无法读取输入。' >&2; exit 1; }
    case "$mode_choice" in
        1) NEW_MODE=TProxy; break ;;
        2) NEW_MODE=TUN; break ;;
        *) echo -e "${RED}无效的选择，请重新输入。${NC}" ;;
    esac
done

if [ "$OLD_MODE" = "$NEW_MODE" ]; then
    echo -e "${GREEN}当前已经是 ${NEW_MODE} 模式，无需切换。${NC}"
    exit 0
fi

systemctl stop sing-box >/dev/null 2>&1 || true

TMP_MODE=$(mktemp /tmp/sbshell-mode.XXXXXX)
BACKUP_MODE=$(mktemp /tmp/sbshell-mode-backup.XXXXXX)
trap 'rm -f "$TMP_MODE" "$BACKUP_MODE"' EXIT
if [ -n "$OLD_MODE" ]; then
    printf 'MODE=%s\n' "$OLD_MODE" > "$BACKUP_MODE"
else
    : > "$BACKUP_MODE"
fi
printf 'MODE=%s\n' "$NEW_MODE" > "$TMP_MODE"
install -o root -g root -m 0644 "$TMP_MODE" "$MODE_FILE"

# 只清理 Sbshell 自有的旧模式防火墙状态（按 state 文件校验所有权）
if ! bash "$SCRIPT_DIR/clean_nft.sh"; then
    install -o root -g root -m 0644 "$BACKUP_MODE" "$MODE_FILE"
    echo -e "${RED}旧模式的防火墙状态无法安全清理，已恢复原模式: ${OLD_MODE:-未设置}${NC}" >&2
    exit 1
fi

echo -e "${GREEN}当前选择模式为:${NEW_MODE} 模式${NC}"
echo "旧模式的 Sbshell 防火墙状态已清理，请继续启动服务以应用新模式。"
