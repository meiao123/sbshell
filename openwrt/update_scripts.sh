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
# --- 下载内容完整性校验（A-12）：与 menu.sh 里的同名函数逐字一致 ---
verify_script_hashes() {
    # $1=清单路径 $2=脚本目录 $3=清单里的路径前缀（如 openwrt）
    local manifest="$1" dir="$2" prefix="$3" hash name actual checked=0
    [ -f "$manifest" ] || { echo '未找到 SHA256SUMS，拒绝安装（无法校验下载内容）。' >&2; return 1; }
    if ! command -v sha256sum >/dev/null 2>&1; then
        echo '未找到 sha256sum，本次跳过下载内容校验（建议使用带 sha256sum 的 busybox 或安装 coreutils-sha256sum）。' >&2
        return 0
    fi
    while read -r hash name; do
        case "$hash" in ''|\#*) continue ;; esac
        case "$name" in "$prefix"/*) ;; *) continue ;; esac
        name=${name#"$prefix"/}
        actual=$(sha256sum "$dir/$name" 2>/dev/null | awk '{print $1}')
        [ -n "$actual" ] || { echo "完整性校验失败：$prefix/$name 未下载成功。" >&2; return 1; }
        [ "$actual" = "$hash" ] || { echo "完整性校验失败：$prefix/$name 与 SHA256SUMS 不符（期望 $hash，实际 $actual）。" >&2; return 1; }
        checked=$((checked + 1))
    done < "$manifest"
    [ "$checked" -gt 0 ] || { echo 'SHA256SUMS 中没有本目录的条目，拒绝安装。' >&2; return 1; }
    return 0
}
# A-18：先装清理 trap（不引用尚未赋值的变量），再逐个创建并检查临时目录。
TMP_DIR=''
BACKUP_DIR=''
cleanup_update_tmp() {
    [ -z "${TMP_DIR:-}" ] || rm -rf "$TMP_DIR"
    [ -z "${BACKUP_DIR:-}" ] || rm -rf "$BACKUP_DIR"
}
trap 'release_scripts_lock; cleanup_update_tmp' EXIT
TMP_DIR=$(mktemp -d /tmp/sbshell-update.XXXXXX) || { echo '无法创建临时目录（/tmp 是否可写？）。' >&2; exit 1; }
BACKUP_DIR=$(mktemp -d /tmp/sbshell-update-backup.XXXXXX) || { echo '无法创建临时目录（/tmp 是否可写？）。' >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
install -d -m 0755 "$SCRIPT_DIR"
# 取锁失败（另一个入口正在更新）就退出，绝不与它交错写入。
acquire_scripts_lock || exit 1
SCRIPTS=(check_environment.sh install_singbox.sh manual_input.sh manual_update.sh auto_update.sh configure_tproxy.sh configure_tun.sh start_singbox.sh stop_singbox.sh clean_nft.sh set_defaults.sh commands.sh switch_mode.sh manage_autostart.sh check_config.sh update_scripts.sh update_ui.sh menu.sh)
for script in "${SCRIPTS[@]}"; do
    download_repo_file "openwrt/$script" "main" "$TMP_DIR/$script"
    # A-23：下载/校验没通过时不能只是静默 exit 1 —— 用户看不到是哪个文件、为什么失败。
    [ -s "$TMP_DIR/$script" ] || { echo -e "${RED}脚本 $script 下载失败或为空，已中止更新（现有安装保持不变）。${NC}" >&2; exit 1; }
    bash -n "$TMP_DIR/$script"
    if head -n1 "$TMP_DIR/$script" | grep -q '^#!/bin/sh'; then sh -n "$TMP_DIR/$script"; fi
done
# A-12：安装前按清单逐个校验下载件，避免半截/被篡改的脚本进 /etc（三个传输层任一层出问题都能拦住）。
download_repo_file "SHA256SUMS" "main" "$TMP_DIR/SHA256SUMS" || exit 1
verify_script_hashes "$TMP_DIR/SHA256SUMS" "$TMP_DIR" openwrt || exit 1
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
