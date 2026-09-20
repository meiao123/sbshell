#!/bin/bash
set -Eeuo pipefail

# --- busybox 兼容：ImmortalWrt/OpenWrt 的 busybox 常常没有 install applet ---
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
SCRIPT_DIR=/etc/sing-box/scripts
REPO_RAW="https://raw.githubusercontent.com/meiao123/sbshell"
github_api_download() {
    local path="$1" ref="$2" output="$3"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github.raw+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com/repos/meiao123/sbshell/contents/$path?ref=$ref" -o "$output" || return 1
    [ -s "$output" ] || { rm -f "$output"; return 1; }
}
github_archive_download() {
    local path="$1" ref="$2" output="$3" archive prefix entry
    command -v tar >/dev/null 2>&1 || return 1
    archive=$(mktemp /tmp/sbshell-archive.XXXXXX) || return 1
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 120 \
        "https://github.com/meiao123/sbshell/archive/$ref.tar.gz" -o "$archive"; then
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
    if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 60 "$REPO_RAW/$ref/$path" -o "$output" 2>/dev/null && [ -s "$output" ]; then
        return 0
    fi
    rm -f "$output"
    if github_api_download "$path" "$ref" "$output"; then
        return 0
    fi
    rm -f "$output"
    github_archive_download "$path" "$ref" "$output"
}
TMP_DIR=$(mktemp -d /tmp/sbshell-update.XXXXXX)
BACKUP_DIR=$(mktemp -d /tmp/sbshell-update-backup.XXXXXX)
trap 'rm -rf "$TMP_DIR" "$BACKUP_DIR"' EXIT
[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
install -d -m 0755 "$SCRIPT_DIR"
SCRIPTS=(check_environment.sh install_singbox.sh manual_input.sh manual_update.sh auto_update.sh configure_tproxy.sh configure_tun.sh start_singbox.sh stop_singbox.sh clean_nft.sh set_defaults.sh commands.sh switch_mode.sh manage_autostart.sh check_config.sh update_scripts.sh update_ui.sh menu.sh)
for script in "${SCRIPTS[@]}"; do
    download_repo_file "openwrt/$script" "main" "$TMP_DIR/$script"
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
