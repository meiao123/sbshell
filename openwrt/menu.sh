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
DEFAULTS_FILE="${SBSHELL_DEFAULTS_FILE:-/etc/sing-box/defaults.conf}"
MANUAL_FILE="${SBSHELL_MANUAL_FILE:-/etc/sing-box/manual.conf}"

# 固定更新版本：先解析 main 当前 commit，再让本次更新全部绑定到该 commit。
export REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/meiao123/sbshell}"
# Raw 传输失败时记录第一行原因（curl 的 stderr），供切换传输层时打印，不再静默。
SBSHELL_RAW_ERR=''
MAIN_REF="main"
GITHUB_API_BASE="https://api.github.com/repos/meiao123/sbshell"
# 兜底端点走 github.com 本体：不受未认证 API「60 次/小时/IP」配额影响。
GITHUB_WEB_BASE="https://github.com/meiao123/sbshell"
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
    # 同一批次只下载一次到 $SBSHELL_ARCHIVE_CACHE，其余文件直接从缓存里 tar -xOzf 提取。
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

SCRIPTS=(check_environment.sh install_singbox.sh manual_input.sh manual_update.sh auto_update.sh configure_tproxy.sh configure_tun.sh start_singbox.sh stop_singbox.sh clean_nft.sh set_defaults.sh commands.sh switch_mode.sh manage_autostart.sh check_config.sh update_scripts.sh update_ui.sh deploy_backend.sh lib.sh menu.sh)
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
    echo -e "${YELLOW}此操作将卸载 Sbshell。你可以选择同时卸载 sing-box，或只保留 sing-box 程序/软件包。${NC}"
    confirm_yes '确定要卸载 Sbshell 吗？' || { echo -e "${GREEN}已取消卸载。${NC}"; return 0; }

    local keep_singbox=0
    if confirm_yes '是否保留 sing-box 软件包及程序？'; then
        keep_singbox=1
        echo -e "${CYAN}已选择保留 sing-box：仅删除 Sbshell、配置/UI/状态等相关文件，不卸载 sing-box 软件包。${NC}"
    else
        echo -e "${CYAN}已选择完整卸载：Sbshell 与 sing-box 一并删除。${NC}"
    fi

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

    if [ "$keep_singbox" -eq 0 ]; then
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
    else
        echo -e "${CYAN}保留 sing-box 软件包，跳过 sing-box 包卸载。${NC}"
        # 配置目录马上会被删除；禁用 sing-box 自启动，避免下次开机时因缺少配置而失败。
        if [ -x /etc/init.d/sing-box ]; then
            /etc/init.d/sing-box disable >/dev/null 2>&1 || true
        fi
        rm -f /etc/rc.d/S99sing-box
    fi

    # A-20：/etc/cron.d/sbshell-ui 与 /etc/cron.d/sbshell-singbox 现在的版本已经不再创建
    # （UI 的计划任务写在 /etc/crontabs/root，见 update_ui.sh），但早期版本留下过它们，
    # 所以这里继续清理以兼容旧安装 —— 注释说明用途，避免被误读成现行 cron.d 布局。
    rm -f /usr/local/bin/sb /usr/bin/sb /etc/cron.d/sbshell-ui /etc/cron.d/sbshell-singbox /etc/sing-box/update-ui.sh /etc/sing-box/update-singbox.sh
    rm -f /etc/crontabs/sbshell-ui 2>/dev/null || true
    if [ -f /etc/crontabs/root ]; then sed -i '/[[:space:]]# sbshell-singbox-auto-update$/d; /[[:space:]]# sbshell-ui-auto-update$/d' /etc/crontabs/root; fi
    if [ -f /etc/init.d/sbshell-firewall ]; then
        /etc/init.d/sbshell-firewall disable >/dev/null 2>&1 || true
    fi
    rm -f /etc/init.d/sbshell-firewall /etc/rc.d/S40sbshell-firewall
    if ! command -v sing-box >/dev/null 2>&1; then
        /etc/init.d/sing-box disable >/dev/null 2>&1 || true
        rm -f /etc/init.d/sing-box /etc/rc.d/S99sing-box
    fi

    rm -rf /etc/sing-box
    if [ "$keep_singbox" -eq 1 ]; then
        echo -e "${GREEN}Sbshell 已卸载，sing-box 软件包/程序已保留；Sbshell 配置、UI、脚本、状态及自启动项已删除。${NC}"
    else
        echo -e "${GREEN}Sbshell 与 sing-box 配置目录已清理；若软件包存在依赖冲突，sing-box 软件包本身会继续保留。${NC}"
    fi
    exit 0
}
# --- 下载内容完整性校验（A-12）：与 update_scripts.sh 里的同名函数逐字一致 ---
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
verify_manifest_entry() {
    local manifest="$1" manifest_name="$2" file="$3" hash actual
    [ -f "$manifest" ] || { echo '未找到 SHA256SUMS，拒绝安装（无法校验下载内容）。' >&2; return 1; }
    if ! command -v sha256sum >/dev/null 2>&1; then
        echo '未找到 sha256sum，本次跳过下载内容校验（建议使用带 sha256sum 的 busybox 或安装 coreutils-sha256sum）。' >&2
        return 0
    fi
    hash=$(awk -v target="$manifest_name" '$2 == target { print $1; exit }' "$manifest")
    [ -n "$hash" ] || { echo "SHA256SUMS 中没有 $manifest_name 的条目。" >&2; return 1; }
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    [ -n "$actual" ] || { echo "完整性校验失败：$manifest_name 未下载成功。" >&2; return 1; }
    [ "$actual" = "$hash" ] || { echo "完整性校验失败：$manifest_name 与 SHA256SUMS 不符（期望 $hash，实际 $actual）。" >&2; return 1; }
    return 0
}

download_script_batch() {
    local commit="$1" transport="$2" tmp_dir="$3" s
    for s in "${SCRIPTS[@]}"; do
        rm -f "$tmp_dir/$s"
        download_repo_file "openwrt/$s" "$commit" "$tmp_dir/$s" "$transport" || return 1
        [ -s "$tmp_dir/$s" ] || return 1
        bash -n "$tmp_dir/$s" || return 1
        if head -n1 "$tmp_dir/$s" | grep -q '^#!/bin/sh' && ! sh -n "$tmp_dir/$s"; then return 1; fi
    done
    rm -f "$tmp_dir/SHA256SUMS"
    download_repo_file "SHA256SUMS" "$commit" "$tmp_dir/SHA256SUMS" "$transport" || return 1
    verify_script_hashes "$tmp_dir/SHA256SUMS" "$tmp_dir" openwrt
}
update_scripts() {
    local tmp backup s rc=0 commit transport verified=0 NEW_SCRIPTS_DIR='' OLD_SCRIPTS_DIR='' extra
    tmp=$(mktemp -d /tmp/sbshell-openwrt.XXXXXX) || return 1
    backup=$(mktemp -d /tmp/sbshell-openwrt-backup.XXXXXX) || { rm -rf "$tmp"; return 1; }
    # 归档缓存：同一批次只下一次 tar.gz（raw/api 都失败时不再逐文件重下）。
    SBSHELL_ARCHIVE_CACHE=$(mktemp /tmp/sbshell-repo-archive.XXXXXX) || SBSHELL_ARCHIVE_CACHE=''
    SBSHELL_ARCHIVE_REF=''
    cleanup_update_ctx() {
        rm -rf "$tmp" "$backup"
        [ -z "${NEW_SCRIPTS_DIR:-}" ] || rm -rf "$NEW_SCRIPTS_DIR"
        [ -z "${SBSHELL_ARCHIVE_CACHE:-}" ] || rm -f "$SBSHELL_ARCHIVE_CACHE"
    }
    restore_scripts() {
        # 目录级部署：交换失败时把旧目录换回来（只有第一次 rename 成功后才存在 .old）。
        [ -d "${OLD_SCRIPTS_DIR:-}" ] || return 0
        rm -rf "$SCRIPT_DIR" 2>/dev/null || true
        mv "$OLD_SCRIPTS_DIR" "$SCRIPT_DIR" 2>/dev/null || true
    }
    # 收到 SIGINT/SIGTERM/SIGHUP 也要回滚并清理临时目录，不能只在 install 返回失败时回滚。
    trap 'restore_scripts; cleanup_update_ctx; exit 1' INT TERM HUP
    commit=$(resolve_main_commit) || { trap - INT TERM HUP; echo -e "${RED}无法获取 main 当前 commit SHA，已中止更新（无法安全固定版本）。${NC}" >&2; cleanup_update_ctx; return 1; }
    # 函数内的 unset 写在 $() 子 shell 里永远无效，只能在父 shell 真正清掉 pin。
    unset SBSHELL_PINNED_COMMIT 2>/dev/null || true
    echo -e "${CYAN}本次脚本更新已固定到 main commit: $commit${NC}"
    for transport in raw api archive; do
        rm -rf "$tmp"; mkdir -p "$tmp" || { trap - INT TERM HUP; cleanup_update_ctx; return 1; }
        if download_script_batch "$commit" "$transport" "$tmp"; then verified=1; break; fi
        case "$transport" in
            raw) echo -e "${YELLOW}Raw 下载失败或完整性校验失败${SBSHELL_RAW_ERR:+（$SBSHELL_RAW_ERR）}，切换 GitHub Contents API。${NC}" >&2 ;;
            api) echo -e "${YELLOW}GitHub Contents API 下载失败或完整性校验失败，切换 commit archive。${NC}" >&2 ;;
            archive) echo -e "${RED}GitHub commit archive 下载或完整性校验仍然失败。${NC}" >&2 ;;
        esac
    done
    if [ "$verified" -ne 1 ]; then trap - INT TERM HUP; cleanup_update_ctx; return 1; fi
    # 目录级原子部署：整套脚本先装进 ${SCRIPT_DIR}.new.XXXXXX，再整体 rename 替换。
    # 逐文件 install 被中断会留下「半新半旧」的脚本集；rename 只有全旧或全新两种状态。
    NEW_SCRIPTS_DIR=$(mktemp -d "${SCRIPT_DIR}.new.XXXXXX") || { trap - INT TERM HUP; echo -e "${RED}无法创建脚本暂存目录，现有安装保持不变。${NC}" >&2; cleanup_update_ctx; return 1; }
    OLD_SCRIPTS_DIR="${SCRIPT_DIR}.old.$$"
    # 目录里的非脚本文件（.initialized 等）必须跟过去，否则会被当成「未初始化」。
    for extra in "$SCRIPT_DIR"/* "$SCRIPT_DIR"/.[!.]*; do
        [ -e "$extra" ] || continue
        case "$(basename "$extra")" in *.sh) continue ;; esac
        cp -a "$extra" "$NEW_SCRIPTS_DIR/" || { trap - INT TERM HUP; echo -e "${RED}复制脚本目录附加文件失败，现有安装保持不变。${NC}" >&2; restore_scripts; cleanup_update_ctx; return 1; }
    done
    for s in "${SCRIPTS[@]}"; do
        if ! install -o root -g root -m 0755 "$tmp/$s" "$NEW_SCRIPTS_DIR/$s"; then
            trap - INT TERM HUP
            echo -e "${RED}写入新脚本失败，现有安装保持不变。${NC}" >&2
            restore_scripts
            cleanup_update_ctx
            return 1
        fi
    done
    chmod 0755 "$NEW_SCRIPTS_DIR" || { trap - INT TERM HUP; restore_scripts; cleanup_update_ctx; return 1; }
    if ! mv "$SCRIPT_DIR" "$OLD_SCRIPTS_DIR"; then
        trap - INT TERM HUP
        echo -e "${RED}替换脚本目录失败，现有安装保持不变。${NC}" >&2
        restore_scripts
        cleanup_update_ctx
        return 1
    fi
    if ! mv "$NEW_SCRIPTS_DIR" "$SCRIPT_DIR"; then
        trap - INT TERM HUP
        restore_scripts
        echo -e "${RED}替换脚本目录失败，已恢复原脚本目录。${NC}" >&2
        cleanup_update_ctx
        return 1
    fi
    NEW_SCRIPTS_DIR=''
    rm -rf "$OLD_SCRIPTS_DIR"
    cleanup_update_ctx
    trap - INT TERM HUP
    return "$rc"
}

run() { bash "$SCRIPT_DIR/$1"; }
# 菜单里单步失败只告警并回到菜单：run() 原样透传退出码，set -e 会连带杀掉整个交互菜单。
run_action() { local rc=0; bash "$SCRIPT_DIR/$1" || rc=$?; [ "$rc" -eq 0 ] || echo -e "${RED}$1 失败（退出码 $rc）。${NC}" >&2; return "$rc"; }

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
    # A-27：不能只透传最后一行。初始化阶段 config.json 还没下载，真实 update_ui.sh 会
    # 先打「UI 安装完成。」再打一句黄字提示，最后一行是提示 —— 用户反而看不到结论。
    # 改为透传关键行；一行都没匹配上时回退到原行为（尾行），保证信息不丢。
    if ui_output=$(run update_ui.sh <<< '1' 2>&1); then
        printf '%s\n' "$ui_output" | grep -E 'UI 安装完成|UI 压缩包下载失败|UI 目录|警告|失败|提示' || printf '%s\n' "$ui_output" | tail -n1
        return 0
    fi
    echo -e "${YELLOW}警告：默认 UI 安装失败，可稍后从菜单「10. 更新控制面板」重试。${NC}" >&2
    printf '%s\n' "$ui_output" | grep -E 'UI 安装完成|UI 压缩包下载失败|UI 目录|警告|失败|提示' || printf '%s\n' "$ui_output" | tail -n1 >&2
    return 1
}

# 初始化阶段：本机后端没在运行时自动做一次 Docker 本地构建（UI 装完、选模式之前）。
# 失败只告警、不阻断初始化：构建要 3~10 分钟且依赖 docker/网络，把它当硬失败会让整套
# 初始化永远进不了菜单（真机踩坑）。
ensure_backend_deployed() {
    if [ "${SBSHELL_SKIP_BACKEND_BUILD:-0}" = 1 ]; then
        echo -e "${YELLOW}[后端] 已通过 SBSHELL_SKIP_BACKEND_BUILD=1 跳过自动构建。${NC}"
        return 0
    fi
    # 与 lib.sh 的 default_or_factory 同语义：defaults.conf 优先，其次 manual.conf（选项 2 写的）；
    # 「键存在但值显式为空」= 用户选择纯模板直连，不能再自作主张去构建本机后端。
    local backend='' have=0 f
    for f in "$DEFAULTS_FILE" "${MANUAL_FILE:-/etc/sing-box/manual.conf}"; do
        [ -f "$f" ] || continue
        grep -q '^BACKEND_URL=' "$f" 2>/dev/null || continue
        backend=$(awk -F= '$1 == "BACKEND_URL" {sub(/^[^=]*=/, ""); print; exit}' "$f" 2>/dev/null || true)
        have=1
        break
    done
    if [ "$have" = 1 ] && [ -z "$backend" ]; then
        echo -e "${YELLOW}[后端] 后端地址被显式留空（纯模板直连），跳过本地构建。${NC}"
        return 0
    fi
    case "$backend" in
        ''|http://127.0.0.1[:/]*|http://localhost[:/]*|http://\[::1\][:/]*) ;;
        *)
            echo -e "${YELLOW}[后端] 默认后端是 $backend（非本机），跳过本地构建。${NC}"
            return 0 ;;
    esac
    if curl --fail --silent --max-time 2 -o /dev/null "http://127.0.0.1:5000/" 2>/dev/null; then
        echo -e "${GREEN}[后端] 本机后端已在运行（127.0.0.1:5000），跳过构建。${NC}"
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}[后端] 未找到 docker：跳过后端本地构建（可先装 docker，再用菜单 12 部署）。${NC}" >&2
        return 0
    fi
    echo -e "${CYAN}[后端] 本机后端未运行，开始 Docker 本地构建（约 3~10 分钟；Ctrl-C 中断后可稍后用菜单 12 重试）…${NC}"
    if bash "$SCRIPT_DIR/deploy_backend.sh"; then
        echo -e "${GREEN}[后端] 后端已就绪。${NC}"
    else
        echo -e "${YELLOW}[后端] 构建/部署失败（初始化继续）；可稍后用菜单 12 重试。${NC}" >&2
    fi
    return 0
}
initialize() {
    update_scripts_locked || { echo -e "${RED}脚本更新失败，现有安装保持不变。${NC}" >&2; return 1; }
    run check_environment.sh || return 1
    run install_singbox.sh || return 1
    # 装完 sing-box 立刻装好默认 UI 并给出通知，之后才让用户选择模式、再走配置输入。
    # 失败不阻断初始化（否则 UI 一失败就会挡住后面所有步骤——真机踩坑）。
    install_default_ui || true
    # UI 装完立刻把本机后端准备好：没有后端时，后面的配置下载必然失败（真机踩坑）。
    ensure_backend_deployed || true
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

# 本机后端体检（P4）：只在默认后端指向回环地址时探测，最多等 2 秒；不可达就给一句可操作提示。
# 远程后端不该被这个检查打扰，所以先看地址前缀。
backend_hint() {
    # 与 lib.sh 的 default_or_factory 同语义：defaults.conf 优先，其次 manual.conf（选项 2 写的）。
    # 这里只是「体检提示」：地址为空（含显式留空）或不是本机时都静默返回，不打扰用户。
    local backend='' f
    for f in "$DEFAULTS_FILE" "${MANUAL_FILE:-/etc/sing-box/manual.conf}"; do
        [ -f "$f" ] || continue
        grep -q '^BACKEND_URL=' "$f" 2>/dev/null || continue
        backend=$(awk -F= '$1 == "BACKEND_URL" {sub(/^[^=]*=/, ""); print; exit}' "$f" 2>/dev/null || true)
        break
    done
    case "$backend" in
        http://127.0.0.1[:/]*|http://localhost[:/]*|http://\[::1\][:/]*) ;;
        *) return 0 ;;
    esac
    curl --fail --silent --max-time 2 -o /dev/null "$backend" 2>/dev/null && return 0
    echo -e "${YELLOW}提示：本机后端 $backend 当前不可达；可用菜单 12 构建/重建后端（Toperlock/sing-box-subscribe）。${NC}" >&2
    return 0
}
backend_hint || true

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
    echo '12. 部署/重建后端（Docker 本地构建）'
    echo '0. 退出'
    echo -e "${CYAN}===============================================${NC}"
    read -rp '请选择操作: ' choice
    # 分支失败只回到菜单继续循环（选 0 仍 exit 0），不再被 set -e 带走整个菜单。
    case "$choice" in
        1) run_action switch_mode.sh && run_action manual_input.sh && run_action start_singbox.sh;;
        2) run_action manual_update.sh;;
        3) run_action auto_update.sh;;
        4) run_action start_singbox.sh;;
        5) run_action stop_singbox.sh;;
        6) run_action set_defaults.sh;;
        7) run_action manage_autostart.sh;;
        8) run_action commands.sh;;
        9) run_action update_scripts.sh;;
        10) run_action update_ui.sh;;
        11) uninstall_sbshell;;
        12) run_action deploy_backend.sh;;
        0) exit 0;;
        *) echo -e "${RED}无效的选择。${NC}";;
    esac || true
done
