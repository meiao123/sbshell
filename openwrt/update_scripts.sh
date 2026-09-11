#!/bin/bash
set -Eeuo pipefail

# --- busybox 兼容：ImmortalWrt/OpenWrt 的 busybox 常常没有 install applet ---
# 真机实测（ImmortalWrt）：一键引导在第一步就中止
#   /dev/fd/64: line 57: install: command not found
# 本仓库大量依赖 GNU install 的 -d/-o/-g/-m，busybox 没有等价命令，因此这里在缺失时
# 定义一个只覆盖本仓库用法的兜底实现；只要系统有真正的 install，这段完全不生效。
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
            [ -n "$m" ] && chmod "$m" "$@" 2>/dev/null
        else
            # 本仓库只用 `install [-m M] [-o U] [-g G] SRC DST`
            [ $# -eq 2 ] || return 1
            cp -f "$1" "$2" || return 1
            [ -n "$m" ] && chmod "$m" "$2" 2>/dev/null
            set -- "$2"
        fi
        [ -n "$o" ] && chown "$o${g:+:$g}" "$@" 2>/dev/null
        return 0
    }
fi
SCRIPT_DIR=/etc/sing-box/scripts
# 内置的发布提交（兜底）：提交无法包含自身 SHA，写死的引用必然指向"上一版"，只信它会出现
# 「装好加固版后点一次更新就回退到修复前版本」的一跳回退（见 docs/security-hardening.md）。
# 真正的发布提交按 main 上的 `RELEASE` 声明解析，只有解析失败才回退到这个常量。
BASE_REF=4e3a090ae5e4d50e35caf78720919153bc272c35
BASE_URL="https://raw.githubusercontent.com/meiao123/sbshell/$BASE_REF/openwrt"
RELEASE_DECL_URL="https://raw.githubusercontent.com/meiao123/sbshell/refs/heads/main/RELEASE"
resolve_release_ref() {
    local declared=''
    declared=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 20 "$RELEASE_DECL_URL" 2>/dev/null | tr -d '\r\n') || declared=''
    case "$declared" in
        *[!0-9a-f]*) ;;
        *) if [ "${#declared}" -eq 40 ]; then
               BASE_REF=$declared
               BASE_URL="https://raw.githubusercontent.com/meiao123/sbshell/$BASE_REF/openwrt"
           fi ;;
    esac
    return 0
}
TMP_DIR=$(mktemp -d /tmp/sbshell-update.XXXXXX)
BACKUP_DIR=$(mktemp -d /tmp/sbshell-update-backup.XXXXXX)
trap 'rm -rf "$TMP_DIR" "$BACKUP_DIR"' EXIT
[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
# 真正下载之前解析发布提交。
resolve_release_ref
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
