#!/bin/bash
set -Eeuo pipefail

# --- busybox 兼容：模拟 install 命令 ---
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
            [ $# -eq 2 ] || return 1
            # 关键修复：先 rm 避免覆盖正在运行中的脚本 inode 导致 Bash 崩溃
            rm -f "$2" 2>/dev/null || true
            cp -f "$1" "$2" || return 1
            [ -z "$m" ] || { chmod "$m" "$2" 2>/dev/null || return 1; }
            set -- "$2"
        fi
        [ -z "$o" ] || { chown "$o${g:+:$g}" "$@" 2>/dev/null || true; }
        return 0
    }
fi

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

SCRIPT_DIR=/etc/sing-box/scripts
INITIALIZED_FILE="$SCRIPT_DIR/.initialized"

# 允许外部传入镜像源，默认提供 ghfast 加速
export REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/meiao123/sbshell}"

github_api_download() {
    local path="$1" ref="$2" output="$3"
    # 注意：api.github.com 不走 ghfast 代理
    curl --fail --silent --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github.raw+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com/repos/meiao123/sbshell/contents/$path?ref=$ref" -o "$output" 2>/dev/null || return 1
    [ -s "$output" ] || { rm -f "$output"; return 1; }
}

github_archive_download() {
    local path="$1" ref="$2" output="$3" archive prefix entry
    command -v tar >/dev/null 2>&1 || return 1
    archive=$(mktemp /tmp/sbshell-archive.XXXXXX) || return 1
    if ! curl --fail --silent --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 120 \
        "https://github.com/meiao123/sbshell/archive/$ref.tar.gz" -o "$archive" 2>/dev/null; then
        rm -f "$archive"
        return 1
    fi
    [ -s "$archive" ] || { rm -f "$archive"; return 1; }
    prefix=$(tar -tzf "$archive" 2>/dev/null | head -n1 | cut -d/ -f1)
    [ -n "$prefix" ] || { rm -f "$archive"; return 1; }
    entry="$prefix/$path"
    case "$entry" in
        *..*|/*) rm -f "$archive"; return 1 ;;
    esac
    tar -xOzf "$archive" "$entry" > "$output" 2>/dev/null || {
        rm -f "$output" "$archive"
        return 1
    }
    rm -f "$archive"
    [ -s "$output" ] || { rm -f "$output"; return 1; }
}

download_repo_file() {
    local path="$1" ref="$2" output="$3"
    # 第一层：直连 / 代理 Raw
    if curl --fail --silent --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 60 "$REPO_RAW/$ref/$path" -o "$output" 2>/dev/null && [ -s "$output" ]; then
        return 0
    fi
    rm -f "$output"
    # 第二层：API 容灾
    if github_api_download "$path" "$ref" "$output"; then
        return 0
    fi
    rm -f "$output"
    # 第三层：全量压缩包解压提取
    github_archive_download "$path" "$ref" "$output"
}

SCRIPTS=(check_environment.sh install_singbox.sh manual_input.sh manual_update.sh auto_update.sh configure_tproxy.sh configure_tun.sh start_singbox.sh stop_singbox.sh clean_nft.sh set_defaults.sh commands.sh switch_mode.sh manage_autostart.sh check_config.sh update_scripts.sh update_ui.sh menu.sh)
install -d -o root -g root -m 0755 "$SCRIPT_DIR"

confirm_yes() { 
    local prompt="$1" answer
    while true; do 
        read -r -p "$prompt [y/n]: " answer || { echo -e "${YELLOW}无法读取输入（EOF），已取消。${NC}" >&2; return 1; }
        case "$answer" in 
            [Yy]) return 0;; 
            [Nn]) return 1;; 
            *) echo -e "${YELLOW}请输入 y 或 n。${NC}";; 
        esac
    done
}

uninstall_sbshell() {
    echo -e "${YELLOW}此操作仅卸载 Sbshell 管理脚本及其快捷方式。${NC}"
    echo -e "${YELLOW}不会删除 sing-box 程序、配置文件、服务或现有代理配置。${NC}"
    confirm_yes '第一次确认：确定要卸载 Sbshell 吗？' || { echo -e "${GREEN}已取消卸载。${NC}"; return 0; }
    confirm_yes '第二次确认：此操作将删除 Sbshell 管理脚本，确定继续吗？' || { echo -e "${GREEN}已取消卸载。${NC}"; return 0; }
    echo -e "${CYAN}正在卸载 Sbshell...${NC}"
    rm -f /usr/local/bin/sb /usr/bin/sb /etc/cron.d/sbshell-ui /etc/cron.d/sbshell-singbox /etc/sing-box/update-ui.sh /etc/sing-box/update-singbox.sh
    rm -f /etc/crontabs/sbshell-ui 2>/dev/null || true
    if [ -f /etc/crontabs/root ]; then sed -i '/[[:space:]]# sbshell-singbox-auto-update$/d; /[[:space:]]# sbshell-ui-auto-update$/d' /etc/crontabs/root; fi
    rm -rf "$SCRIPT_DIR"
    echo -e "${GREEN}Sbshell 已卸载。sing-box 及其现有配置已保留。${NC}"
    exit 0
}

update_scripts() {
        local tmp backup s rc=0
    local -a backed_up=()
    tmp=$(mktemp -d /tmp/sbshell-openwrt.XXXXXX) || return 1
    backup=$(mktemp -d /tmp/sbshell-openwrt-backup.XXXXXX) || { rm -rf "$tmp"; return 1; }
    
    restore_scripts() {
        local item
        for item in "${backed_up[@]}"; do
            install -o root -g root -m 0755 "$backup/$item" "$SCRIPT_DIR/$item" || true
        done
    }

    # 关键修复：加入 openwrt/ 前缀
    for s in "${SCRIPTS[@]}"; do
        if ! download_repo_file "openwrt/$s" "main" "$tmp/$s" || [ ! -s "$tmp/$s" ] || ! bash -n "$tmp/$s"; then
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

if [ ! -f "$INITIALIZED_FILE" ]; then
    echo -e "${CYAN}回车进入初始化，输入 skip 跳过：${NC}"
    read -r choice
    if [[ "$choice" =~ ^[Ss]kip$ ]]; then
        update_scripts || exit 1
    else
        initialize || exit 1
    fi
else
    [ -f "$SCRIPT_DIR/menu.sh" ] || update_scripts || exit 1
fi

while true; do
    echo -e "${CYAN}=========== Sbshell OpenWrt 管理菜单 ===========${NC}"
    echo '1. TProxy/TUN 模式切换'
    echo '2. 手动更新配置'
    echo '3. 自动更新配置'
    echo '4. 启动 sing-box'
    echo '5. 停止 sing-box'
    echo '6. 默认参数设置'
    echo '7. 设置自启动'
    echo '8. 常用命令'
    echo '9. 更新脚本'
    echo '10. 更新控制面板'
    echo -e "11. ${RED}卸载Sbshell${NC}"
    echo '0. 退出'
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
        11) uninstall_sbshell;;
        0) exit 0;;
        *) echo -e "${RED}无效的选择。${NC}";;
    esac
done
