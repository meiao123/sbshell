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
# 固定更新版本：先解析 main 当前 commit，再让本次更新全部绑定到该 commit。
export REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/meiao123/sbshell}"
# Raw 传输失败时记录第一行原因（curl 的 stderr），供切换传输层时打印，不再静默。
SBSHELL_RAW_ERR=''
MAIN_REF="main"
GITHUB_API_BASE="https://api.github.com/repos/meiao123/sbshell"
# 兜底端点走 github.com 本体：不受未认证 API「60 次/小时/IP」配额影响。
GITHUB_WEB_BASE="https://github.com/meiao123/sbshell"
# 独立入口：menu.sh 用 run() 以子进程方式启动本脚本，父进程的变量不会继承，
# 而本脚本在 set -u 下运行，未定义的变量会直接终止更新。颜色与 SCRIPT_DIR 必须在此定义。
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
SCRIPT_DIR=/etc/sing-box/scripts
resolve_main_commit() {
    local endpoint response_file err_file curl_args main_sha

    case "${SBSHELL_PINNED_COMMIT:-}" in
        ''|*[!0-9a-fA-F]*) ;;
        *)
            if [ "${#SBSHELL_PINNED_COMMIT}" -eq 40 ]; then
                printf '%s\n' "$SBSHELL_PINNED_COMMIT"
                return 0
            fi
            ;;
    esac

    response_file=$(mktemp /tmp/sbshell-main-ref.XXXXXX) || return 1
    err_file="${response_file}.err"

    # 第一优先：Commits API，返回顶层 sha，避免依赖嵌套 ref 结构。
    for curl_args in '' '-4'; do
        endpoint="$GITHUB_API_BASE/commits/$MAIN_REF"
        rm -f "$response_file" "$err_file"
        if curl $curl_args --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 8 --max-time 20 \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "$endpoint" -o "$response_file" 2>"$err_file"; then
            main_sha=$(grep -m1 -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{40}"' "$response_file" 2>/dev/null | sed -n 's/.*"\([0-9a-fA-F]\{40\}\)".*/\1/p')
            if [ -n "$main_sha" ] && [ "${#main_sha}" -eq 40 ]; then
                rm -f "$response_file" "$err_file"
                printf '%s\n' "$main_sha"
                return 0
            fi
        fi
    done

    # 第二优先：Git Ref API，兼容旧版/不同 API 响应。
    for curl_args in '' '-4'; do
        endpoint="$GITHUB_API_BASE/git/ref/heads/$MAIN_REF"
        rm -f "$response_file" "$err_file"
        if curl $curl_args --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 8 --max-time 20 \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "$endpoint" -o "$response_file" 2>"$err_file"; then
            main_sha=$(grep -m1 -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{40}"' "$response_file" 2>/dev/null | sed -n 's/.*"\([0-9a-fA-F]\{40\}\)".*/\1/p')
            if [ -n "$main_sha" ] && [ "${#main_sha}" -eq 40 ]; then
                rm -f "$response_file" "$err_file"
                printf '%s\n' "$main_sha"
                return 0
            fi
        fi
    done

    # 第三优先：github.com 本体（不经 api.github.com）。未认证 API 只有 60 次/小时/IP，
    # 出口被 CGNAT/其它工具打满时会 403；github.com 与 raw 不受该配额限制。
    # atom feed 的 <id> 形如 Grit::Commit/<sha>；commit/main.patch 的首行是 `From <sha> …`。
    for endpoint in "$GITHUB_WEB_BASE/commits/$MAIN_REF.atom" "$GITHUB_WEB_BASE/commit/$MAIN_REF.patch"; do
        rm -f "$response_file" "$err_file"
        if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 8 --max-time 20 "$endpoint" -o "$response_file" 2>"$err_file"; then
            main_sha=$(grep -m1 -oE 'Grit::Commit/[0-9a-fA-F]{40}' "$response_file" 2>/dev/null | sed 's#.*/##')
            [ -n "$main_sha" ] || main_sha=$(grep -m1 -oE '^From [0-9a-fA-F]{40}' "$response_file" 2>/dev/null | sed 's/^From //')
            if [ -n "$main_sha" ] && [ "${#main_sha}" -eq 40 ]; then
                rm -f "$response_file" "$err_file"
                printf '%s\n' "$main_sha"
                return 0
            fi
        fi
    done

echo "获取 main commit SHA 失败：API 与 github.com 兜底端点都拿不到当前 commit。" >&2
if [ -s "$err_file" ]; then
    err_text=$(tr '\n' ' ' < "$err_file" | sed 's/[[:space:]]\+/ /g' | cut -c1-240)
    echo "最后一次请求错误：$err_text" >&2
    case "$err_text" in
        *403*|*rate*limit*)
            echo '提示：403 多为未认证 API 限流（60 次/小时/IP）。可等待配额重置，或用 SBSHELL_PINNED_COMMIT=<40 位 commit> 跳过解析。' >&2
            ;;
    esac
fi
rm -f "$response_file" "$err_file"
return 1
}
github_api_download() {
    local path="$1" ref="$2" output="$3"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github.raw+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
        "$GITHUB_API_BASE/contents/$path?ref=$ref" -o "$output" || return 1
    [ -s "$output" ] || { rm -f "$output"; return 1; }
}
github_archive_download() {
    local path="$1" ref="$2" output="$3" archive prefix entry
    command -v tar >/dev/null 2>&1 || return 1
    # 归档缓存：raw/api 都失败时，旧实现会为每个文件各下一次 tar.gz（19 次 × max-time 120）。
    # 同一批次只下载一次到 $SBSHELL_ARCHIVE_CACHE，其余文件直接从缓存里 tar -xOzf 提取；
    # 缓存变量为空（例如 sbshall.sh 的引导路径）时退回逐次下载，语义不变。
    if [ -n "${SBSHELL_ARCHIVE_CACHE:-}" ] && [ "${SBSHELL_ARCHIVE_REF:-}" = "$ref" ] && [ -s "$SBSHELL_ARCHIVE_CACHE" ]; then
        archive="$SBSHELL_ARCHIVE_CACHE"
    else
        archive=$(mktemp /tmp/sbshell-archive.XXXXXX) || return 1
        if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 \
            "https://github.com/meiao123/sbshell/archive/$ref.tar.gz" -o "$archive"; then
            rm -f "$archive"; return 1
        fi
        [ -s "$archive" ] || { rm -f "$archive"; return 1; }
        if [ -n "${SBSHELL_ARCHIVE_CACHE:-}" ]; then
            if mv -f "$archive" "$SBSHELL_ARCHIVE_CACHE"; then
                archive="$SBSHELL_ARCHIVE_CACHE"
                SBSHELL_ARCHIVE_REF="$ref"
            fi
        fi
    fi
    list=$(mktemp /tmp/sbshell-archive-list.XXXXXX) || { rm -f "$archive"; return 1; }
    if ! tar -tzf "$archive" > "$list" 2>/dev/null; then rm -f "$list"; return 1; fi
    first=$(head -n1 "$list") || true; prefix=${first%%/*}; rm -f "$list"
    [ -n "$prefix" ] || return 1
    entry="$prefix/$path"
    case "$entry" in *..*|/*) return 1;; esac
    tar -xOzf "$archive" "$entry" > "$output" 2>/dev/null || { rm -f "$output"; return 1; }
    [ -s "$output" ] || { rm -f "$output"; return 1; }
}
download_repo_file() {
    local path="$1" ref="$2" output="$3" transport="$4" raw_err_file
    case "$transport" in
        raw)
            # 失败原因必须可见：旧写法把 curl 的 stderr 丢进 /dev/null，用户只看到
            #「Raw 下载失败」，无法判断是限流、DNS 还是 404。只留第一行，避免 19 个文件刷屏。
            raw_err_file=$(mktemp /tmp/sbshell-raw-err.XXXXXX 2>/dev/null || echo "/tmp/sbshell-raw-err.$$")
            if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
                "$REPO_RAW/$ref/$path" -o "$output" 2>"$raw_err_file"; then
                if [ -s "$output" ]; then rm -f "$raw_err_file"; SBSHELL_RAW_ERR=''; return 0; fi
                SBSHELL_RAW_ERR='下载内容为空'
            else
                SBSHELL_RAW_ERR=$(sed -n '1p' "$raw_err_file" 2>/dev/null | cut -c1-160)
                [ -n "$SBSHELL_RAW_ERR" ] || SBSHELL_RAW_ERR='curl 请求失败'
            fi
            rm -f "$raw_err_file" ;;
        api) github_api_download "$path" "$ref" "$output"; return $? ;;
        archive) github_archive_download "$path" "$ref" "$output"; return $? ;;
        *) return 2 ;;
    esac
    rm -f "$output"; return 1
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
        waited=$((waited + 1))
        if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
            # 属主已死/pid 缺失（kill -9、掉电、断线都常见）：给 5 秒宽限后直接接管。
            # stat 不可用时 created=0、age 永远是 0，必须用 waited 兜底，否则就是无限静默挂起。
            if [ "$age" -ge 5 ] || { [ "$created" -eq 0 ] && [ "$waited" -ge 5 ]; }; then
                rm -rf "$SCRIPTS_LOCK_DIR" 2>/dev/null || true
                sleep 1
                continue
            fi
        fi
        # 硬上限：不论属主死活，等满超时就报错返回（旧实现某些路径会永不返回）。
        if [ "$waited" -ge "$SCRIPTS_LOCK_TIMEOUT" ]; then
            echo '等待脚本更新锁超时（另一个进程正在更新脚本）。' >&2
            return 1
        fi
        # 每 5 秒报一次进度：否则用户看到的是「按回车后毫无反应」。
        case $((waited % 5)) in
            0) echo "等待脚本更新锁（持有者 pid ${owner:-未知}，已等待 ${waited}s）…" >&2 ;;
        esac
        sleep 1
    done
    printf '%s\n' "$$" > "$SCRIPTS_LOCK_DIR/pid"
}
# --- 下载内容完整性校验（A-12）：与 menu.sh 里的同名函数逐字一致 ---
verify_script_hashes() {
    # $1=清单路径 $2=脚本目录 $3=清单里的路径前缀（如 openwrt）
    local manifest="$1" dir="$2" prefix="$3" hash name actual checked=0 total=0
    [ -f "$manifest" ] || { echo '未找到 SHA256SUMS，拒绝安装（无法校验下载内容）。' >&2; return 1; }
    if ! command -v sha256sum >/dev/null 2>&1; then
        # 精简固件只有 busybox 的 sha256sum applet：用函数兜底，保留下面的调用写法。
        if command -v busybox >/dev/null 2>&1; then
            sha256sum() { busybox sha256sum "$@"; }
        else
            echo '未找到 sha256sum，本次跳过下载内容校验（建议使用带 sha256sum 的 busybox 或安装 coreutils-sha256sum）。' >&2
            return 0
        fi
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
    # 覆盖数必须等于目录里的脚本数：新增脚本忘加哈希时不能只校验老脚本就安装。
    for name in "$dir"/*.sh; do [ -e "$name" ] || continue; total=$((total + 1)); done
    [ "$total" -eq "$checked" ] || { echo "SHA256SUMS 只覆盖 $checked/$total 个脚本，拒绝安装（新增脚本可能没有哈希）。" >&2; return 1; }
    return 0
}
# A-18：先装清理 trap（不引用尚未赋值的变量），再逐个创建并检查临时目录。
download_script_batch() {
    local commit="$1" transport="$2" tmp_dir="$3" script
    for script in "${SCRIPTS[@]}"; do
        rm -f "$tmp_dir/$script"
        download_repo_file "openwrt/$script" "$commit" "$tmp_dir/$script" "$transport" || return 1
        [ -s "$tmp_dir/$script" ] || return 1
        bash -n "$tmp_dir/$script" || return 1
        if head -n1 "$tmp_dir/$script" | grep -q '^#!/bin/sh' && ! sh -n "$tmp_dir/$script"; then return 1; fi
    done
    rm -f "$tmp_dir/SHA256SUMS"
    download_repo_file "SHA256SUMS" "$commit" "$tmp_dir/SHA256SUMS" "$transport" || return 1
    verify_script_hashes "$tmp_dir/SHA256SUMS" "$tmp_dir" openwrt
}
TMP_DIR=''
BACKUP_DIR=''
# 归档缓存与暂存目录在清理 trap 里统一回收（trap 安装时都还没有值，必须 ${VAR:-} 保护）。
SBSHELL_ARCHIVE_CACHE=''
SBSHELL_ARCHIVE_REF=''
NEW_SCRIPTS_DIR=''
cleanup_update_tmp() {
    [ -z "${TMP_DIR:-}" ] || rm -rf "$TMP_DIR"
    [ -z "${BACKUP_DIR:-}" ] || rm -rf "$BACKUP_DIR"
    [ -z "${NEW_SCRIPTS_DIR:-}" ] || rm -rf "$NEW_SCRIPTS_DIR"
    [ -z "${SBSHELL_ARCHIVE_CACHE:-}" ] || rm -f "$SBSHELL_ARCHIVE_CACHE"
}
trap 'release_scripts_lock; cleanup_update_tmp' EXIT
TMP_DIR=$(mktemp -d /tmp/sbshell-update.XXXXXX) || { echo '无法创建临时目录（/tmp 是否可写？）。' >&2; exit 1; }
BACKUP_DIR=$(mktemp -d /tmp/sbshell-update-backup.XXXXXX) || { echo '无法创建临时目录（/tmp 是否可写？）。' >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
install -d -m 0755 "$SCRIPT_DIR"
# 取锁失败（另一个入口正在更新）就退出，绝不与它交错写入。
acquire_scripts_lock || exit 1
SCRIPTS=(check_environment.sh install_singbox.sh manual_input.sh manual_update.sh auto_update.sh configure_tproxy.sh configure_tun.sh start_singbox.sh stop_singbox.sh clean_nft.sh set_defaults.sh commands.sh switch_mode.sh manage_autostart.sh check_config.sh update_scripts.sh update_ui.sh deploy_backend.sh lib.sh menu.sh)
commit=$(resolve_main_commit) || { echo -e "${RED}无法获取 main 当前 commit SHA，已中止更新（无法安全固定版本）。${NC}" >&2; exit 1; }
# 函数内的 unset 写在 $() 子 shell 里永远无效，只能在父 shell 真正清掉 pin。
unset SBSHELL_PINNED_COMMIT 2>/dev/null || true
echo -e "本次脚本更新已固定到 main commit: $commit"
verified=0
for transport in raw api archive; do
    rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR" || exit 1
    if download_script_batch "$commit" "$transport" "$TMP_DIR"; then verified=1; break; fi
    case "$transport" in
        raw) echo -e "${YELLOW}Raw 下载失败或完整性校验失败${SBSHELL_RAW_ERR:+（$SBSHELL_RAW_ERR）}，切换 GitHub Contents API。${NC}" >&2 ;;
        api) echo -e "${YELLOW}GitHub Contents API 下载失败或完整性校验失败，切换 commit archive。${NC}" >&2 ;;
        archive) echo -e "${RED}GitHub commit archive 下载或完整性校验仍然失败。${NC}" >&2 ;;
    esac
done
[ "$verified" -eq 1 ] || exit 1
# 目录级原子部署：先把整套脚本装进 ${SCRIPT_DIR}.new.XXXXXX，再整体 rename 替换。
# 逐文件 install 的旧做法被中断时会留下「半新半旧」的脚本集；rename 只有全旧或全新两种状态。
# 正在运行的 menu.sh 已经打开了旧 inode，目录被换走不会影响它的继续执行。
NEW_SCRIPTS_DIR=$(mktemp -d "${SCRIPT_DIR}.new.XXXXXX") || { echo '无法创建脚本暂存目录，现有安装保持不变。' >&2; exit 1; }
OLD_SCRIPTS_DIR="${SCRIPT_DIR}.old.$$"
restore_dir() {
    # 交换过程失败时把旧目录换回来（只有第一次 rename 成功后才存在 .old）。
    [ -d "$OLD_SCRIPTS_DIR" ] || return 0
    rm -rf "$SCRIPT_DIR" 2>/dev/null || true
    mv "$OLD_SCRIPTS_DIR" "$SCRIPT_DIR" 2>/dev/null || true
}
# 收到 SIGINT/SIGTERM/SIGHUP 时也要回滚并释放锁，不能只在 install 返回失败时回滚。
trap 'restore_dir; cleanup_update_tmp; release_scripts_lock; exit 1' INT TERM HUP
# 目录里可能有非脚本文件（.initialized 等），整体替换前先带过去，否则会被当成"未初始化"。
for extra in "$SCRIPT_DIR"/* "$SCRIPT_DIR"/.[!.]*; do
    [ -e "$extra" ] || continue
    case "$(basename "$extra")" in *.sh) continue ;; esac
    cp -a "$extra" "$NEW_SCRIPTS_DIR/" || { echo '复制脚本目录附加文件失败，现有安装保持不变。' >&2; restore_dir; exit 1; }
done
for script in "${SCRIPTS[@]}"; do
    if ! install -o root -g root -m 0755 "$TMP_DIR/$script" "$NEW_SCRIPTS_DIR/$script"; then
        echo '写入新脚本失败，现有安装保持不变。' >&2
        restore_dir
        exit 1
    fi
done
chmod 0755 "$NEW_SCRIPTS_DIR" || { restore_dir; exit 1; }
if ! mv "$SCRIPT_DIR" "$OLD_SCRIPTS_DIR"; then
    echo '替换脚本目录失败，现有安装保持不变。' >&2
    restore_dir
    exit 1
fi
if ! mv "$NEW_SCRIPTS_DIR" "$SCRIPT_DIR"; then
    restore_dir
    echo '替换脚本目录失败，已恢复原脚本目录。' >&2
    exit 1
fi
NEW_SCRIPTS_DIR=''
rm -rf "$OLD_SCRIPTS_DIR"
trap - INT TERM HUP
echo 'OpenWrt 管理脚本已完成审核发布引用下载、语法校验和事务式更新。'
