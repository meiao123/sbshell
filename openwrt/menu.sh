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
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
SCRIPT_DIR=/etc/sing-box/scripts
INITIALIZED_FILE="$SCRIPT_DIR/.initialized"
# 内置的发布提交（兜底）：提交无法包含自身 SHA，写死的引用必然指向"上一版"，只信它会出现
# 「装好加固版后点一次更新就回退到修复前版本」的一跳回退（见 docs/security-hardening.md）。
# 真正的发布提交按 main 上的 `RELEASE` 声明解析，只有解析失败才回退到这个常量。
BASE_REF=91865d43c91b5d22141d412c27d3c54624c4be95
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
SCRIPTS=(check_environment.sh install_singbox.sh manual_input.sh manual_update.sh auto_update.sh configure_tproxy.sh configure_tun.sh start_singbox.sh stop_singbox.sh clean_nft.sh set_defaults.sh commands.sh switch_mode.sh manage_autostart.sh check_config.sh update_scripts.sh update_ui.sh menu.sh)
install -d -o root -g root -m 0755 "$SCRIPT_DIR"
confirm_yes() { local prompt="$1" answer; while true; do read -r -p "$prompt [y/n]: " answer || { echo -e "${YELLOW}无法读取输入（EOF），已取消。${NC}" >&2; return 1; }; case "$answer" in [Yy]) return 0;; [Nn]) return 1;; *) echo -e "${YELLOW}请输入 y 或 n。${NC}";; esac; done; }
uninstall_sbshell() {
    echo -e "${YELLOW}此操作仅卸载 Sbshell 管理脚本及其快捷方式。${NC}"
    echo -e "${YELLOW}不会删除 sing-box 程序、配置文件、服务或现有代理配置。${NC}"
    confirm_yes '第一次确认：确定要卸载 Sbshell 吗？' || { echo -e "${GREEN}已取消卸载。${NC}"; return 0; }
    confirm_yes '第二次确认：此操作将删除 Sbshell 管理脚本，确定继续吗？' || { echo -e "${GREEN}已取消卸载。${NC}"; return 0; }
    echo -e "${CYAN}正在卸载 Sbshell...${NC}"
    rm -f /usr/local/bin/sb /etc/cron.d/sbshell-ui /etc/cron.d/sbshell-singbox /etc/sing-box/update-ui.sh /etc/sing-box/update-singbox.sh
    rm -f /etc/crontabs/sbshell-ui 2>/dev/null || true
    if [ -f /etc/crontabs/root ]; then sed -i '/[[:space:]]# sbshell-singbox-auto-update$/d; /[[:space:]]# sbshell-ui-auto-update$/d' /etc/crontabs/root; fi
    rm -rf "$SCRIPT_DIR"
    echo -e "${GREEN}Sbshell 已卸载。sing-box 及其现有配置已保留。${NC}"
    exit 0
}
update_scripts() {
    # 下载前解析发布提交：只用内置常量会退回上一版（见 docs/security-hardening.md）。
    resolve_release_ref
    local tmp backup s item rc=0
    # 两个 mktemp 都要检查（原因同 debian/menu.sh）。
    tmp=$(mktemp -d /tmp/sbshell-openwrt.XXXXXX) || return 1
    backup=$(mktemp -d /tmp/sbshell-openwrt-backup.XXXXXX) || { rm -rf "$tmp"; return 1; }
    # 只回滚确实备份成功的脚本（见 debian/menu.sh 的说明）。
    backed_up=()
    restore_scripts() {
        local item
        for item in "${backed_up[@]}"; do
            install -o root -g root -m 0755 "$backup/$item" "$SCRIPT_DIR/$item" || true
        done
    }
    for s in "${SCRIPTS[@]}"; do
        if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$BASE_URL/$s" -o "$tmp/$s" ||
            [ ! -s "$tmp/$s" ] ||
            ! bash -n "$tmp/$s"; then
            rc=1
            break
        fi
        if head -n1 "$tmp/$s" | grep -q '^#!/bin/sh' && ! sh -n "$tmp/$s"; then
            rc=1
            break
        fi
    done
    if [ "$rc" -eq 0 ]; then
        for s in "${SCRIPTS[@]}"; do
            if [ -f "$SCRIPT_DIR/$s" ]; then
                if ! cp -a "$SCRIPT_DIR/$s" "$backup/$s"; then
                    echo -e "${RED}备份 $s 失败，已中止更新（现有安装保持不变）。${NC}" >&2
                    rc=1
                    break
                fi
                backed_up+=("$s")
            fi
        done
    fi
    if [ "$rc" -eq 0 ]; then
        for s in "${SCRIPTS[@]}"; do
            if ! install -o root -g root -m 0755 "$tmp/$s" "$SCRIPT_DIR/$s"; then
                restore_scripts
                rc=1
                break
            fi
        done
    fi
    rm -rf "$tmp" "$backup"
    return "$rc"
}
run() { bash "$SCRIPT_DIR/$1"; }
initialize() {
    update_scripts || { echo -e "${RED}脚本更新失败，现有安装保持不变。${NC}" >&2; return 1; }
    run check_environment.sh || return 1
    run install_singbox.sh || return 1
    run switch_mode.sh || return 1
    run manual_input.sh || return 1
    run start_singbox.sh || return 1
    touch "$INITIALIZED_FILE" && chmod 0644 "$INITIALIZED_FILE"
}
if [ ! -f "$INITIALIZED_FILE" ]; then echo -e "${CYAN}回车进入初始化，输入 skip 跳过：${NC}"; read -r choice; if [[ "$choice" =~ ^[Ss]kip$ ]]; then update_scripts || exit 1; else initialize || exit 1; fi; else [ -f "$SCRIPT_DIR/menu.sh" ] || update_scripts || exit 1; fi
while true; do
    echo -e "${CYAN}=========== Sbshell OpenWrt 管理菜单 ===========${NC}"
    echo '1. TProxy/TUN 模式切换'; echo '2. 手动更新配置'; echo '3. 自动更新配置'; echo '4. 启动 sing-box'; echo '5. 停止 sing-box'; echo '6. 默认参数设置'; echo '7. 设置自启动'; echo '8. 常用命令'; echo '9. 更新脚本'; echo '10. 更新控制面板'; echo -e "11. ${RED}卸载Sbshell${NC}"; echo '0. 退出'
    read -rp '请选择操作: ' choice
    case "$choice" in
        1) run switch_mode.sh; run manual_input.sh; run start_singbox.sh;; 2) run manual_update.sh;; 3) run auto_update.sh;; 4) run start_singbox.sh;; 5) run stop_singbox.sh;; 6) run set_defaults.sh;; 7) run manage_autostart.sh;; 8) run commands.sh;; 9) run update_scripts.sh;; 10) run update_ui.sh;; 11) uninstall_sbshell;; 0) exit 0;; *) echo -e "${RED}无效的选择。${NC}";;
    esac
done
