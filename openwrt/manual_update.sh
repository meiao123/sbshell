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
MANUAL_FILE=/etc/sing-box/manual.conf
DEFAULTS_FILE=/etc/sing-box/defaults.conf
CONFIG_FILE=/etc/sing-box/config.json
BACKUP_FILE=/etc/sing-box/config.json.bak
MODE_FILE=/etc/sing-box/mode.conf
LOCK_DIR=/tmp/sbshell-config.lock
LOCK_TIMEOUT=900
# 先提权再建临时目录（exec 不触发 EXIT trap）。
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
TMP_DIR=$(mktemp -d /tmp/sbshell-config.XXXXXX) || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT

read_value() { awk -F= -v k="$1" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$2" 2>/dev/null || true; }
valid_url() { [[ "$1" =~ ^https?://[^[:space:]]+$ ]]; }
# A-28：http:// 与 https:// 都接受 —— 后端/订阅/模板地址是「参数」，真实下载地址由它们拼出来，
# 内网或本机回环后端（例如 http://127.0.0.1:5000/）是常见且合法的用法。
# 明文 HTTP 只提示、不阻断：回环地址静默通过，其它主机提示凭据会明文经过网络。
warn_plaintext_http() {
    case "$1" in
        http://127.0.0.1[:/]*|http://localhost[:/]*|http://\[::1\][:/]*) return 0 ;;
        http://*) echo "提示：$1 使用明文 HTTP，凭据会明文经过网络，请仅在可信内网使用。" >&2 ;;
    esac
    return 0
}
valid_subscription() {
    local value="$1"
    [ -z "$value" ] && return 0
    case "$value" in
        *[[:space:]]*|*'&file='*|*'#'*) return 1 ;;
    esac
    return 0
}
build_full_url() {
    if [ -n "$BACKEND_URL" ]; then
        FULL_URL="${BACKEND_URL%/}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"
    else
        FULL_URL="$TEMPLATE_URL"
    fi
}
validate_endpoints() {
    if [ -n "$BACKEND_URL" ]; then
        valid_url "$BACKEND_URL" || { echo -e "${RED}后端地址必须是 http:// 或 https:// 的 URL。${NC}" >&2; return 1; }
        [ -n "$SUBSCRIPTION_URL" ] || { echo -e "${RED}使用后端地址时订阅地址不能为空。${NC}" >&2; return 1; }
    fi
    valid_subscription "$SUBSCRIPTION_URL" || { echo -e "${RED}订阅地址包含非法字符。${NC}" >&2; return 1; }
    valid_url "$TEMPLATE_URL" || { echo -e "${RED}配置文件地址必须是 http:// 或 https:// 的 URL。${NC}" >&2; return 1; }
    build_full_url
    valid_url "$FULL_URL" || { echo -e "${RED}生成的订阅 URL 无效。${NC}" >&2; return 1; }
    warn_plaintext_http "$FULL_URL"
    return 0
}
release_lock() {
    [ -d "$LOCK_DIR" ] || return 0
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    [ "$owner" = "$$" ] && rm -rf "$LOCK_DIR"
}
acquire_lock() {
        waited=0
        while ! mkdir "$LOCK_DIR" 2>/dev/null; do
            owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
            case "$owner" in ''|*[!0-9]*) owner='' ;; esac
            now=$(date +%s)
            created=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
            age=0
            [ "$created" -gt 0 ] && age=$((now - created))
            if [ "$age" -ge "$LOCK_TIMEOUT" ]; then
                rm -rf "$LOCK_DIR" 2>/dev/null || true
                sleep 1
                continue
            fi
            if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
                waited=$((waited + 1))
                if [ "$waited" -ge "$LOCK_TIMEOUT" ]; then
                    echo -e "${RED}等待配置锁超时（另一个进程持锁）。${NC}" >&2
                    return 1
                fi
            fi
            sleep 1
        done
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        trap 'release_lock; rm -rf "$TMP_DIR"' EXIT
        trap 'release_lock; rm -rf "$TMP_DIR"; exit 1' INT TERM
    }
MODE=$(read_value MODE "$MODE_FILE")

confirm_yes() {
    local prompt="$1" answer
    while true; do
        read -r -p "$prompt [y/n]: " answer || { echo -e "${RED}无法读取输入，操作已取消。${NC}" >&2; return 1; }
        case "$answer" in
            [Yy]) return 0;;
            [Nn]) return 1;;
            *) echo -e "${RED}请输入 y 或 n。${NC}";;
        esac
    done
}

prompt_user_input() {
    while true; do
        read -rp '后端地址(留空使用默认): ' BACKEND_URL || { echo -e "${RED}无法读取后端地址。${NC}" >&2; return 1; }
        BACKEND_URL=${BACKEND_URL:-$(read_value BACKEND_URL "$DEFAULTS_FILE")}
        read -rp '订阅地址(留空使用默认): ' SUBSCRIPTION_URL || { echo -e "${RED}无法读取订阅地址。${NC}" >&2; return 1; }
        SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$(read_value SUBSCRIPTION_URL "$DEFAULTS_FILE")}
        read -rp '配置文件地址(留空使用默认): ' TEMPLATE_URL || { echo -e "${RED}无法读取配置文件地址。${NC}" >&2; return 1; }
        if [ -z "$TEMPLATE_URL" ]; then
            case "$MODE" in
                TProxy) TEMPLATE_URL=$(read_value TPROXY_TEMPLATE_URL "$DEFAULTS_FILE");;
                TUN) TEMPLATE_URL=$(read_value TUN_TEMPLATE_URL "$DEFAULTS_FILE");;
                *) echo -e "${RED}未知模式，无法从默认值读取配置文件地址。${NC}" >&2; return 1;;
            esac
        fi
        validate_endpoints && return 0
    done
}

if ! confirm_yes '是否重新设置配置文件地址？'; then
    [ -f "$MANUAL_FILE" ] || { echo -e "${RED}未找到已记录的配置地址，请选择重新设置。${NC}" >&2; exit 1; }
    BACKEND_URL=$(read_value BACKEND_URL "$MANUAL_FILE")
    SUBSCRIPTION_URL=$(read_value SUBSCRIPTION_URL "$MANUAL_FILE")
    TEMPLATE_URL=$(read_value TEMPLATE_URL "$MANUAL_FILE")
    validate_endpoints || exit 1
else
    while true; do
        prompt_user_input || exit 1
        if confirm_yes '确认地址无误吗？'; then
            break
        fi
    done
    printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TEMPLATE_URL" > "$TMP_DIR/manual.conf"
fi

acquire_lock
if [ -f "$MANUAL_FILE" ]; then cp -a "$MANUAL_FILE" "$TMP_DIR/manual.backup" || { echo -e "${RED}备份地址配置失败。${NC}" >&2; exit 1; }; fi
if [ -f "$CONFIG_FILE" ]; then cp -a "$CONFIG_FILE" "$BACKUP_FILE" || { echo -e "${RED}旧配置备份失败，已取消更新。${NC}" >&2; exit 1; }; fi

# 与初始化路径（manual_input.sh）一致：30s 超时 + 实时倒计时。curl 放进后台子 shell 写状态文件，
# 前台显示倒计时；子 shell 内用 `|| rc=$?` 兜住退出码（本脚本是 set -Eeuo pipefail，裸 curl 失败
# 会直接终止子 shell，状态文件永远写不出来，父进程只能空转到超时并误报原因）。
# 与 manual_input.sh 逐字相同的失败原因解释器（两脚本互不 source，只能内联）。
download_failure_reason() {
    reason_rc="${1:-}"
    reason_http="${2:-}"
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

download_status=$(mktemp /tmp/sbshell-update-status.XXXXXX)
download_http=$(mktemp /tmp/sbshell-update-http.XXXXXX)
# A-26：不要 rm 这个文件（同名符号链接抢注 + 子 shell `>` 跟随会写到任意文件）；
# 父进程等的是“文件为空”，mktemp 的空文件同样满足，保留它语义不变。
(
    rc=0
    # A-28：允许 http —— 这里请求的是用户自己的后端，回环/内网后端经常就是 http；
    # 非回环的明文 HTTP 已由 warn_plaintext_http 提示风险，不再阻断。
    # -w 把 HTTP 状态码写进单独文件：失败时才能区分 5xx / 401 / 403 / 404。
    curl --fail --silent --show-error --location --proto '=http,https' --tlsv1.2 --connect-timeout 10 --max-time 30 -w '%{http_code}' "$FULL_URL" -o "$TMP_DIR/config.json" > "$download_http" || rc=$?
    printf '%s\n' "$rc" > "$download_status"
    exit 0
) &
curl_pid=$!
elapsed=0
while [ ! -s "$download_status" ]; do
    remaining=$((30 - elapsed))
    [ "$remaining" -ge 0 ] || remaining=0
    printf '\r配置文件下载中，超时倒计时: %02ds' "$remaining"
    if [ "$elapsed" -ge 30 ]; then
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done
if [ ! -s "$download_status" ]; then
    kill "$curl_pid" 2>/dev/null || true
    wait "$curl_pid" 2>/dev/null || true
    printf '\n'
    echo -e "${RED}新配置下载超时（30s，$(download_failure_reason 28)），已保留之前的 config.json。${NC}" >&2
    rm -f "$download_status" "$download_http"
    exit 1
fi
wait "$curl_pid" 2>/dev/null || true
download_rc=$(cat "$download_status" 2>/dev/null || echo 1)
download_http_code=$(cat "$download_http" 2>/dev/null || true)
rm -f "$download_status" "$download_http"
if [ "$download_rc" -ne 0 ]; then
    printf '\n'
    # 与初始化路径（manual_input.sh）一致：给出 curl 退出码对应的具体原因与 HTTP 状态码，
    # 不要只说「下载失败」。这里**不打印请求 URL**（其中含订阅 token）。
    echo -e "${RED}新配置下载失败（$(download_failure_reason "$download_rc" "$download_http_code")），已保留之前的 config.json。${NC}" >&2
    exit 1
fi
printf '\r配置文件下载中，超时倒计时: 00s\n'
if ! sing-box check -c "$TMP_DIR/config.json"; then
    echo -e "${RED}新配置验证失败，已保留之前的 config.json。${NC}" >&2
    exit 1
fi

if [ -f "$TMP_DIR/manual.conf" ]; then
    install -o root -g root -m 0600 "$TMP_DIR/manual.conf" "$MANUAL_FILE" || { echo -e "${RED}新地址保存失败，已保留之前的配置。${NC}" >&2; exit 1; }
fi
install -o root -g root -m 0600 "$TMP_DIR/config.json" "$CONFIG_FILE" || {
    [ ! -f "$BACKUP_FILE" ] || install -o root -g root -m 0600 "$BACKUP_FILE" "$CONFIG_FILE"
    [ ! -f "$TMP_DIR/manual.backup" ] || install -o root -g root -m 0600 "$TMP_DIR/manual.backup" "$MANUAL_FILE"
    echo -e "${RED}新配置写入失败，已恢复旧配置。${NC}" >&2
    exit 1
}

# 重启沿用仓库其它入口的写法：rc.common/procd 在没有已注册实例时会回显 ubus 的「没有东西可删」
# 噪音，两种形态都要过滤：短形态 `Command failed: Not found`，以及带命令名的长形态
# `Command failed: ubus call service delete { "name": "sing-box" } (Not found)`。
if ! /etc/init.d/sing-box restart 2> >(sed '/^Command failed:.*Not found/d' >&2) || ! sleep 2 || ! pidof sing-box >/dev/null 2>&1; then
    [ ! -f "$BACKUP_FILE" ] || install -o root -g root -m 0600 "$BACKUP_FILE" "$CONFIG_FILE"
    [ ! -f "$TMP_DIR/manual.backup" ] || install -o root -g root -m 0600 "$TMP_DIR/manual.backup" "$MANUAL_FILE"
    /etc/init.d/sing-box restart 2> >(sed '/^Command failed:.*Not found/d' >&2) || true
    echo -e "${RED}新配置启动失败，已恢复旧配置。${NC}" >&2
    exit 1
fi

echo -e "${GREEN}配置更新并启动成功。旧配置已备份到 $BACKUP_FILE。${NC}"
