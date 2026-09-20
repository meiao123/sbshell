#!/bin/bash
set -Eeuo pipefail



# --- busybox 兼容：ImmortalWrt/OpenWrt 的 busybox 常常没有 install applet ---
# 真机实测（ImmortalWrt）：一键引导在第一步就中止
#   /dev/fd/64: line 57: install: command not found
# 本仓库大量依赖 GNU install 的 -d/-o/-g/-m，busybox 没有等价命令，因此这里在缺失时
# 定义一个只覆盖本仓库用法的兜底实现；只要系统有真正的 install，这段完全不生效。
#
# 与调用方 `set -Eeuo pipefail` 的关系（踩过坑）：
#   * chmod 失败必须让本次 install **返回非 0**（fail-closed：凭据文件绝不能悄悄留在 0644），
#     并且要 `return 1` 而不是让 errexit 在函数内部直接终止整个脚本——否则调用方的
#     `if ! install …; then restore; fi` 回滚逻辑根本没机会执行；
#   * chown 失败不影响返回码（所有权不构成安全边界，且 vfat/extroot 等文件系统上会失败）。
# 写法上一律用 `[ -z "$x" ] || { cmd … || …; }`：判空为真时整行返回 0，
# 且 `cmd` 处于 `||` 列表首位时不受 errexit 影响，失败能被显式处理。
if ! command -v install >/dev/null 2>&1; then
    install() {
        local d=0 m='' o='' g=''
        while [ $# -gt 0 ]; do
            case "$1" in
                -d) d=1; shift ;;
                -m) m="$2"; shift 2 ;;
                -o) o="$2"; shift 2 ;;
                -g) g="$2"; shift 2 ;;
                -*) shift ;;
                *) break ;;
            esac
        done
        if [ "$d" -eq 1 ]; then
            mkdir -p "$@" || return 1
            [ -z "$m" ] || { chmod "$m" "$@" 2>/dev/null || return 1; }
        else
            # 本仓库只用 `install [-m M] [-o U] [-g G] SRC DST`
            [ $# -eq 2 ] || return 1
            # 先 rm 再写，避免覆盖正在运行脚本的 inode（写正在执行的脚本会 ETXTBSY 而失败）。
            rm -f "$2" 2>/dev/null || true
            cp -f "$1" "$2" || return 1
            [ -z "$m" ] || { chmod "$m" "$2" 2>/dev/null || return 1; }
            set -- "$2"
        fi
        [ -z "$o" ] || { chown "$o${g:+:$g}" "$@" 2>/dev/null || true; }
        return 0
    }
fi

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
    echo -e "${RED}旧模式的防火墙状态无法安全清理，已恢复原模式: ${OLD_MODE:-未设置}${NC}" >&2
    exit 1
fi

echo -e "${GREEN}当前选择模式为:${NEW_MODE} 模式${NC}"
echo "旧模式的 Sbshell 防火墙状态已清理，请继续启动服务以应用新模式。"
