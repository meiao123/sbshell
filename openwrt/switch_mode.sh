#!/bin/bash
set -Eeuo pipefail

# 公共实现（install 兜底、防火墙参数）集中在 lib.sh，避免三份副本漂移。
_sbshell_lib_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$_sbshell_lib_dir/lib.sh" || { echo '缺少 lib.sh，请先在菜单 9 更新脚本。' >&2; exit 1; }

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
MODE_FILE=/etc/sing-box/mode.conf
SCRIPT_DIR=/etc/sing-box/scripts

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
case "$OLD_MODE" in TProxy|TUN) ;; *) OLD_MODE='';; esac

while true; do
    read -rp "请选择模式(1: TProxy 模式, 2: TUN 模式): " mode_choice
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

/etc/init.d/sing-box stop 2> >(sed '/^Command failed:.*Not found/d' >&2)
# 原子写（A-16）：mode.conf 是"当前模式"的唯一真相源，而 /tmp 与 /etc 通常不在同一个文件
# 系统（tmpfs vs overlay）。旧写法用 install（OpenWrt 上是就地截断的 cp -f），窗口内被读到
# 空内容时，configure_tproxy.sh/configure_tun.sh 的 `[ "$MODE" = … ] || exit 0` 会静默什么都
# 不做——表现为"启动成功但没有规则"。临时文件与备份都放到目标同目录，再用 mv 原子替换。
MODE_DIR=$(dirname "$MODE_FILE")
mkdir -p "$MODE_DIR"
TMP_MODE=$(mktemp "$MODE_DIR/.mode.conf.XXXXXX")
BACKUP_MODE=$(mktemp "$MODE_DIR/.mode.conf.backup.XXXXXX")
trap 'rm -f "$TMP_MODE" "$BACKUP_MODE"' EXIT
if [ -n "$OLD_MODE" ]; then
    printf 'MODE=%s\n' "$OLD_MODE" > "$BACKUP_MODE"
else
    : > "$BACKUP_MODE"
fi
printf 'MODE=%s\n' "$NEW_MODE" > "$TMP_MODE"
chmod 0644 "$TMP_MODE"; chown root:root "$TMP_MODE"
mv -f "$TMP_MODE" "$MODE_FILE"

if ! bash "$SCRIPT_DIR/clean_nft.sh"; then
    chmod 0644 "$BACKUP_MODE"; chown root:root "$BACKUP_MODE"
    mv -f "$BACKUP_MODE" "$MODE_FILE"
    # D1：服务已在上面停掉，恢复 mode.conf 后必须尝试重启，否则"已恢复原模式"实际是停服状态。
    /etc/init.d/sing-box start >/dev/null 2>&1 || true
    echo -e "${RED}旧模式的防火墙状态无法安全清理，已恢复原模式: ${OLD_MODE:-未设置} 并尝试重新启动 sing-box；若启动失败请执行菜单 4 手动启动${NC}" >&2
    exit 1
fi

echo -e "${GREEN}当前选择模式为:${NEW_MODE} 模式${NC}"
echo "旧模式的 Sbshell 防火墙状态已清理，请继续启动服务以应用新模式。"
