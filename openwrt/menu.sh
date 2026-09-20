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
    # 不要写成 `tar -tzf "$archive" | head -n1`：head 先退出会让 tar 收到 SIGPIPE（rc=141），
    # 在 set -o pipefail 下赋值失败、脚本直接中止 —— 只有大归档才会命中（小归档碰巧正常）。
    list=$(mktemp /tmp/sbshell-archive-list.XXXXXX) || { rm -f "$archive"; return 1; }
    if ! tar -tzf "$archive" > "$list" 2>/dev/null; then
        rm -f "$archive" "$list"
        return 1
    fi
    first=$(head -n1 "$list") || true
    prefix=${first%%/*}
    rm -f "$list"
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
    echo -e "${YELLOW}此操作将卸载 Sbshell、sing-box、配置文件及其管理的防火墙状态。${NC}"
    confirm_yes '确定要卸载 Sbshell 吗？' || { echo -e "${GREEN}已取消卸载。${NC}"; return 0; }

    echo -e "${CYAN}正在停止 sing-box 并清理防火墙...${NC}"
    if pidof sing-box >/dev/null 2>&1; then
        if ! /etc/init.d/sing-box stop 2> >(sed '/^Command failed:.*Not found/d' >&2); then
            echo -e "${RED}停止 sing-box 失败，已取消卸载。${NC}" >&2
            return 1
        fi
    else
        echo -e "${GREEN}sing-box 未运行，无需重复停止。${NC}"
    fi
    if ! bash "$SCRIPT_DIR/clean_nft.sh"; then
        echo -e "${RED}防火墙清理失败，已取消卸载，避免留下残余代理状态。${NC}" >&2
        return 1
    fi

    echo -e "${CYAN}正在卸载 sing-box 软件包及 Sbshell...${NC}"
    if command -v opkg >/dev/null 2>&1; then
        if opkg remove sing-box >/dev/null 2>&1; then
            :
        else
            echo -e "${YELLOW}sing-box 软件包当前无法卸载（可能被其他软件包依赖），已保留 sing-box，继续清理 Sbshell 文件。${NC}" >&2
        fi
    elif command -v apk >/dev/null 2>&1; then
        if apk del sing-box >/dev/null 2>&1; then
            :
        else
            echo -e "${YELLOW}sing-box 软件包当前无法卸载（可能被其他软件包依赖），已保留 sing-box，继续清理 Sbshell 文件。${NC}" >&2
        fi
    else
        echo -e "${YELLOW}未找到 opkg 或 apk，无法卸载 sing-box 软件包，继续清理 Sbshell 文件。${NC}" >&2
    fi

    rm -f /usr/local/bin/sb /usr/bin/sb /etc/cron.d/sbshell-ui /etc/cron.d/sbshell-singbox /etc/sing-box/update-ui.sh /etc/sing-box/update-singbox.sh
    rm -f /etc/crontabs/sbshell-ui 2>/dev/null || true
    if [ -f /etc/crontabs/root ]; then sed -i '/[[:space:]]# sbshell-singbox-auto-update$/d; /[[:space:]]# sbshell-ui-auto-update$/d' /etc/crontabs/root; fi
    # 卸载后不能留下指向已删除脚本的开机启动项：/etc/sing-box 紧接着就会被删掉，
    # 而 Sbshell 自己写的 /etc/init.d/sbshell-firewall（START=40）每次开机都会去执行
    # 已经不存在的 manage_autostart.sh，在 init 日志里留下失败记录。
    if [ -f /etc/init.d/sbshell-firewall ]; then
        /etc/init.d/sbshell-firewall disable >/dev/null 2>&1 || true
    fi
    rm -f /etc/init.d/sbshell-firewall /etc/rc.d/S40sbshell-firewall
    # sing-box 软件包确实已不在时，Sbshell 写过的 /etc/init.d/sing-box 与它的 rc.d 链接同样
    # 指向不存在的二进制；包仍然存在时那属于包自己的文件，不能碰。
    if ! command -v sing-box >/dev/null 2>&1; then
        /etc/init.d/sing-box disable >/dev/null 2>&1 || true
        rm -f /etc/init.d/sing-box /etc/rc.d/S99sing-box
    fi
    rm -rf /etc/sing-box
    echo -e "${GREEN}Sbshell 与 sing-box 配置目录已清理；若软件包存在依赖冲突，sing-box 软件包本身会继续保留。${NC}"
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

UI_DIR=/etc/sing-box/ui

# 安装默认 UI（zashboard）：已装好就直接返回。失败只告警并返回非 0，由调用方决定是否阻断——
# 需求是「先把 UI 装完并给出通知，再弹出菜单；UI 失败就先给警告再弹菜单」。
# --- 脚本更新互斥（A-15）：menu.sh 的自动更新与 update_scripts.sh 都会重写 $SCRIPT_DIR 里
# 同一批脚本，两个入口并发会交错安装不同批次的文件。这里用与配置/UI 更新同一套 mkdir 锁实现
# （/tmp 世界可写，因此 pid 必须是纯数字、过期按 mtime 判定、并有 waited 硬上限）。
SCRIPTS_LOCK_DIR=/tmp/sbshell-scripts.lock
SCRIPTS_LOCK_TIMEOUT=900
release_scripts_lock() {
    [ -d "$SCRIPTS_LOCK_DIR" ] || return 0
    owner=$(cat "$SCRIPTS_LOCK_DIR/pid" 2>/dev/null || true)
    [ "$owner" = "$$" ] && rm -rf "$SCRIPTS_LOCK_DIR"
}
acquire_scripts_lock() {
    waited=0
    while ! mkdir "$SCRIPTS_LOCK_DIR" 2>/dev/null; do
        owner=$(cat "$SCRIPTS_LOCK_DIR/pid" 2>/dev/null || true)
        case "$owner" in ''|*[!0-9]*) owner='' ;; esac
        now=$(date +%s)
        created=$(stat -c %Y "$SCRIPTS_LOCK_DIR" 2>/dev/null || echo 0)
        age=0
        [ "$created" -gt 0 ] && age=$((now - created))
        if [ "$age" -ge "$SCRIPTS_LOCK_TIMEOUT" ]; then
            rm -rf "$SCRIPTS_LOCK_DIR" 2>/dev/null || true
            sleep 1
            continue
        fi
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
            waited=$((waited + 1))
            if [ "$waited" -ge "$SCRIPTS_LOCK_TIMEOUT" ]; then
                echo '等待脚本更新锁超时（另一个进程正在更新脚本）。' >&2
                return 1
            fi
        fi
        sleep 1
    done
    printf '%s\n' "$$" > "$SCRIPTS_LOCK_DIR/pid"
}
# 持锁调用：menu.sh 是长驻的交互进程，不能靠 EXIT trap 释放（那会一直持到退出菜单），
# 因此在这里显式成对 acquire/release。
update_scripts_locked() {
    local rc=0
    acquire_scripts_lock || { echo -e "${RED}另一个进程正在更新脚本，已跳过本次自动更新。${NC}" >&2; return 1; }
    trap 'release_scripts_lock; exit 1' INT TERM
    update_scripts || rc=$?
    release_scripts_lock
    trap - INT TERM
    return "$rc"
}

install_default_ui() {
    [ -f "$UI_DIR/index.html" ] && return 0
    # 同一次运行里只尝试一次：初始化阶段失败过就不再重试，避免重复下载、无谓拉长等待。
    [ -z "${UI_INSTALL_TRIED:-}" ] || return 1
    UI_INSTALL_TRIED=1
    local ui_output
    echo -e "${CYAN}正在安装默认 UI...${NC}"
    if ui_output=$(run update_ui.sh <<< '1' 2>&1); then
        printf '%s\n' "$ui_output" | tail -n1
        return 0
    fi
    echo -e "${YELLOW}警告：默认 UI 安装失败，可稍后从菜单「10. 更新控制面板」重试。${NC}" >&2
    printf '%s\n' "$ui_output" | tail -n1 >&2
    return 1
}

initialize() {
    update_scripts_locked || { echo -e "${RED}脚本更新失败，现有安装保持不变。${NC}" >&2; return 1; }
    run check_environment.sh || return 1
    run install_singbox.sh || return 1
    # 装完 sing-box 立刻装好默认 UI 并给出通知，之后才让用户选择模式、再走配置输入。
    # 失败不阻断初始化（否则 UI 一失败就会挡住后面所有步骤——真机踩坑）。
    install_default_ui || true
    run switch_mode.sh || return 1
    # 管理脚本、sing-box 和网络模式已经完成基础初始化；之后即使配置下载失败，
    # 再次执行 sb 也应直接进入菜单，而不是重复执行完整初始化。
    touch "$INITIALIZED_FILE" && chmod 0644 "$INITIALIZED_FILE"
    run manual_input.sh || return 1
    run start_singbox.sh || return 1
}

if [ ! -f "$INITIALIZED_FILE" ]; then
    echo -e "${CYAN}回车进入初始化，输入 skip 跳过：${NC}"
    read -r choice
    if [[ "$choice" =~ ^[Ss]kip$ ]]; then
        update_scripts_locked || exit 1
    else
        initialize || exit 1
    fi
else
    [ -f "$SCRIPT_DIR/menu.sh" ] || update_scripts_locked || exit 1
fi

# 已初始化过的机器（含历史安装中断、从未装过 UI 的）在进菜单前自动补装一次；
# 失败只告警，不阻挡菜单显示。
install_default_ui || true

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
    echo '11. 卸载Sbshell'
    echo '0. 退出'
    echo -e "${CYAN}===============================================${NC}"
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
