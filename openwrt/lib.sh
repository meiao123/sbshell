#!/bin/bash
# lib.sh —— Sbshell 公共库
#
# 目的：把此前内联在 10 个脚本里的同一批实现收敛到一处，避免「修了一份、漏了另一份」。
# 这些重复曾经导致真实缺陷：cron 版的 ensure_unzip 做了重定向、交互版没做；选项 2 修了
# 模板空值回退、初始化路径没修；订阅校验在四个入口各写一遍。
#
# 用法（脚本头部，其它定义之前）：
#   _sbshell_lib_dir=$(cd "$(dirname "$0")" && pwd)
#   # shellcheck source=lib.sh
#   . "$_sbshell_lib_dir/lib.sh" || { echo '缺少 lib.sh，请先在菜单 9 更新脚本。' >&2; exit 1; }
#
# 仍然必须各自内联、不能依赖本库的三处（有意为之，不是遗漏）：
#   * sbshall.sh / menu.sh：一键引导时只安装了 menu.sh，lib.sh 尚未落地；
#   * install_singbox.sh：#!/bin/sh（busybox ash），不能加载 bash 库；
#   * auto_update.sh 生成的 /etc/sing-box/update-singbox.sh：cron 脚本必须自包含。
#
# 说明：本库假定调用方已经 `set -Eeuo pipefail`；函数内部一律判空、不用未定义变量。

# ---------- 1. busybox install 兜底 ----------
# ImmortalWrt/OpenWrt 的 busybox 常常没有 install applet，本仓库大量依赖 GNU install 的
# -d/-o/-g/-m。缺失时定义只覆盖本仓库用法的兜底实现；有真正的 install 时完全不生效。
#
# 与调用方 `set -Eeuo pipefail` 的关系（踩过坑）：
#   * chmod 失败必须让本次 install **返回非 0**（fail-closed：凭据文件绝不能悄悄留在 0644），
#     并且要 `return 1` 而不是让 errexit 在函数内部直接终止整个脚本——否则调用方的
#     `if ! install …; then restore; fi` 回滚逻辑根本没机会执行；
#   * chown 失败不影响返回码（所有权不构成安全边界，且 vfat/extroot 等文件系统上会失败）。
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

# ---------- 2. 键值文件读取与默认值解析 ----------
# 读 KEY=VALUE 文件的单键；值里允许出现 '='（URL 的查询串）。文件不存在时返回空。
read_value() { # $1=键  $2=文件
    awk -F= -v k="$1" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$2" 2>/dev/null || true
}

# 默认值解析：菜单 6 写入的 defaults.conf 优先；该键缺失或为空时回退 manual.conf
# ——也就是设备上当前已经生效的地址。
#   $3=1：键存在即采用（后端/订阅允许「显式空值」，纯模板模式才能切得过去）
#   $3=0：值为空仍回退（模板地址不能为空）
# 依赖调用方的 DEFAULTS_FILE / MANUAL_FILE 两个变量（脚本里本来就定义了）。
resolve_default() { # $1=defaults.conf 的键  $2=manual.conf 的键  $3=1 允许显式空值
    local value
    if grep -q "^$1=" "$DEFAULTS_FILE" 2>/dev/null; then
        value=$(read_value "$1" "$DEFAULTS_FILE")
        [ -n "$value" ] || [ "${3:-0}" -eq 1 ] || value=$(read_value "$2" "$MANUAL_FILE")
    else
        value=$(read_value "$2" "$MANUAL_FILE")
    fi
    printf '%s' "$value"
}

# ---------- 3. 地址校验、明文提示与脱敏 ----------
# A-28：http:// 与 https:// 都接受 —— 后端/订阅/模板地址是「参数」，真实下载地址由它们拼出来，
# 内网或本机回环后端（例如 http://127.0.0.1:5000/）是常见且合法的用法。
valid_url() { [[ "$1" =~ ^https?://[^[:space:]]+$ ]]; }

# 明文 HTTP 只提示、不阻断：回环地址静默通过，其它主机提示凭据会明文经过网络。
warn_plaintext_http() {
    case "$1" in
        http://127.0.0.1[:/]*|http://localhost[:/]*|http://\[::1\][:/]*) return 0 ;;
        http://*) echo "提示：配置地址使用明文 HTTP，凭据可能明文经过网络，请仅在可信内网使用。" >&2 ;;
    esac
    return 0
}

# 订阅地址（FULL_URL）里含用户 token：任何输出都不该带原文，终端回滚、截图、粘贴给别人
# 排查都会把它带出去。只保留 scheme+host，其余以 *** 代替。
redact_url() {
    local u="$1" scheme rest host
    case "$u" in
        *://*)
            scheme=${u%%://*}
            rest=${u#*://}
            host=${rest%%/*}
            printf '%s://%s/***' "$scheme" "$host"
            ;;
        *) printf '%s' "$u" ;;
    esac
}

# 订阅地址不是 URL（是后端约定的查询串），但必须排除空白、'#' 以及会覆盖 file 参数的片段。
valid_subscription() {
    local value="$1"
    [ -z "$value" ] && return 0
    case "$value" in
        *[[:space:]]*|*'&file='*|*'#'*) return 1 ;;
    esac
    return 0
}

# ---------- 4. 下载失败原因翻译 ----------
# 把 curl 的退出码（以及 --fail 中止时仍会输出的 HTTP 状态码）翻译成能直接看懂的原因。
# 真机踩坑（ImmortalWrt 25.12.2）：后端返回 HTTP 500，日志里却只有一句"下载超时"。
download_failure_reason() {
    local reason_rc="${1:-}" reason_http="${2:-}"
    # -w 输出可能在异常情况下混入非数字内容，先过滤掉，别让数值比较报错。
    case "$reason_http" in ''|*[!0-9]*) reason_http='' ;; esac
    case "$reason_rc" in
        5)  echo '无法解析代理地址（--proxy 配置有误）' ;;
        6)  echo '域名解析失败（DNS 无法解析该主机）' ;;
        7)  echo '连接被拒绝（目标端口没有服务在监听）' ;;
        22) if [ -z "$reason_http" ]; then
                echo '服务器返回 HTTP 错误'
            elif [ "$reason_http" -ge 500 ]; then
                echo "服务器返回 HTTP $reason_http（服务端出错：多为后端拉取上游订阅或模板失败）"
            elif [ "$reason_http" = 401 ] || [ "$reason_http" = 403 ]; then
                echo "服务器返回 HTTP $reason_http（鉴权失败或无权访问）"
            elif [ "$reason_http" = 404 ]; then
                echo "服务器返回 HTTP $reason_http（地址不存在）"
            else
                echo "服务器返回 HTTP $reason_http"
            fi ;;
        28) echo '请求超时（服务器未在限时内响应）' ;;
        35|51|60) echo 'TLS/证书校验失败' ;;
        56) echo '接收数据失败（连接被重置）' ;;
        *)  echo "curl 退出码 ${reason_rc:-未知}" ;;
    esac
}

# ---------- 5. 互斥锁 ----------
# 目录锁：mkdir 原子创建；pid 必须是纯数字；mtime 过期即接管（pid 复用/伪造时也能恢复）。
# 与旧实现的区别（P2）：属主已死或 pid 缺失时不再空等满 timeout —— 锁龄超过 5 秒直接接管，
# 否则一次 kill -9/掉电会让菜单"看起来卡死"最多 15 分钟。
#   锁目录：$1  超时秒数：$2  可选清理函数：$3（会在 EXIT/INT/TERM 里与放锁一起执行）
acquire_lock() {
    local dir="$1" timeout="$2" cleanup="${3:-}" waited=0 owner now created age
    while ! mkdir "$dir" 2>/dev/null; do
        owner=$(cat "$dir/pid" 2>/dev/null || true)
        case "$owner" in ''|*[!0-9]*) owner='' ;; esac
        now=$(date +%s)
        created=$(stat -c %Y "$dir" 2>/dev/null || echo 0)
        age=0
        [ "$created" -gt 0 ] && age=$((now - created))
        if [ "$age" -ge "$timeout" ]; then
            # 过期即接管：不能只凭 owner 是否存活判断（pid 复用或伪造 pid 会让过期分支永远到不了）
            rm -rf "$dir" 2>/dev/null || true
            sleep 1
            continue
        fi
        if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
            # 属主已死：给 5 秒宽限（避开 mkdir 与写 pid 之间的正常窗口）后直接接管。
            if [ "$age" -ge 5 ]; then
                rm -rf "$dir" 2>/dev/null || true
                sleep 1
                continue
            fi
        else
            waited=$((waited + 1))
            if [ "$waited" -ge "$timeout" ]; then
                echo '等待配置锁超时（另一个进程持锁）。' >&2
                return 1
            fi
        fi
        sleep 1
    done
    printf '%s\n' "$$" > "$dir/pid"
    if [ -n "$cleanup" ]; then
        trap "$cleanup; release_lock $dir" EXIT
        trap "$cleanup; release_lock $dir; exit 1" INT TERM
    else
        trap "release_lock $dir" EXIT
        trap "release_lock $dir; exit 1" INT TERM
    fi
    return 0
}

# 只允许属主删除锁目录（pid 复用/他人代删都不会误删别人的锁）。
release_lock() {
    local dir="$1" owner
    [ -d "$dir" ] || return 0
    owner=$(cat "$dir/pid" 2>/dev/null || true)
    [ "$owner" = "$$" ] && rm -rf "$dir"
    return 0
}

# ---------- 6. 原子提交 ----------
# 把文件提交到目标路径：同目录临时文件 → install 写入 → mv（rename）替换。
# 直接 install 到目标时（真机兜底是「先 rm 再 cp」）中途失败会连旧文件一起弄丢，
# 断电/被杀还会留下半截内容；rename 语义下目标要么是旧的、要么是完整的新内容。
commit_file() { # $1=源文件  $2=目标文件  $3=权限（默认 0600）
    local src="$1" dst="$2" mode="${3:-0600}" tmp
    tmp=$(mktemp "$(dirname "$dst")/.$(basename "$dst").XXXXXX") || return 1
    if ! install -m "$mode" "$src" "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod "$mode" "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$dst"; then
        rm -f "$tmp"
        return 1
    fi
    return 0
}

# ---------- 7. 防火墙共用参数 ----------
# 旧实现把这些常量分别写死在 configure_tproxy.sh / configure_tun.sh / clean_nft.sh 里，
# 三处必须永远一致；现在集中在这里，并允许用环境变量覆盖（与外部规则共存、调试时有用）。
SBSHELL_ROUTING_MARK=${SBSHELL_ROUTING_MARK:-666}
SBSHELL_PROXY_FWMARK=${SBSHELL_PROXY_FWMARK:-1}
SBSHELL_ROUTE_TABLE=${SBSHELL_ROUTE_TABLE:-100}
SBSHELL_RULE_PREF=${SBSHELL_RULE_PREF:-10010}
SBSHELL_RESERVED_V4=${SBSHELL_RESERVED_V4:-'{ 127.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 198.51.100.0/24, 192.168.0.0/16, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4, 255.255.255.255/32 }'}
SBSHELL_BYPASS_V4=${SBSHELL_BYPASS_V4:-'{ 192.168.0.0/16, 10.0.0.0/8 }'}
