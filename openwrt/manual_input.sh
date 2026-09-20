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

CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

MANUAL_FILE=/etc/sing-box/manual.conf
DEFAULTS_FILE=/etc/sing-box/defaults.conf
CONFIG_FILE=/etc/sing-box/config.json
MODE_FILE=/etc/sing-box/mode.conf
LOCK_DIR=/tmp/sbshell-config.lock
LOCK_TIMEOUT=900

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

get_default() {
    local key="$1"
    grep -m1 "^${key}=" "$DEFAULTS_FILE" 2>/dev/null | cut -d'=' -f2- || true
}
valid_url() { [[ "$1" =~ ^https://[^[:space:]]+$ ]]; }
valid_subscription() {
    local value="$1"
    [ -z "$value" ] && return 0
    case "$value" in
        *[[:space:]]*|*'&file='*|*'#'*) return 1 ;;
    esac
    return 0
}

# 把 curl 的退出码（以及 --fail 中止时仍会输出的 HTTP 状态码）翻译成能直接看懂的原因。
# 真机踩坑（ImmortalWrt 25.12.2）：后端返回 HTTP 500，日志里却只有一句"下载超时"，
# 用户完全看不出是服务端出错。这里只做翻译，不改变任何失败处理流程。
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

release_lock() {
    [ -d "$LOCK_DIR" ] || return 0
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    [ "$owner" = "$$" ] && rm -rf "$LOCK_DIR"
}
acquire_lock() {
        waited=0
        while ! mkdir "$LOCK_DIR" 2>/dev/null; do
            owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
            # pid 必须是纯数字，否则视为无效
            case "$owner" in ''|*[!0-9]*) owner='' ;; esac
            now=$(date +%s)
            created=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
            age=0
            [ "$created" -gt 0 ] && age=$((now - created))
            # 过期即接管：不能只凭 owner 是否存活判断（pid 复用或伪造 pid 会让
            # 过期分支永远到不了，配置更新会永久阻塞）
            if [ "$age" -ge "$LOCK_TIMEOUT" ]; then
                rm -rf "$LOCK_DIR" 2>/dev/null || true
                sleep 1
                continue
            fi
            if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
                waited=$((waited + 1))
                if [ "$waited" -ge "$LOCK_TIMEOUT" ]; then
                    echo '等待配置锁超时（另一个进程持锁）。' >&2
                    return 1
                fi
            fi
            sleep 1
        done
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        trap 'cleanup; release_lock' EXIT
        trap 'cleanup; release_lock; exit 1' INT TERM
    }

MODE=$(sed -n 's/^MODE=//p' "$MODE_FILE" 2>/dev/null | head -n1)
TMP_FILES=()
cleanup() { local file; for file in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do rm -f "$file" 2>/dev/null || true; done; }
trap cleanup EXIT

while true; do
    read -rp '请输入后端地址(回车使用默认值可留空): ' BACKEND_URL
    BACKEND_URL=${BACKEND_URL:-$(get_default BACKEND_URL)}
    read -rp '请输入订阅地址(回车使用默认值可留空): ' SUBSCRIPTION_URL
    SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$(get_default SUBSCRIPTION_URL)}
    read -rp '请输入配置文件地址(回车使用默认值可留空): ' TEMPLATE_URL
    if [ -z "$TEMPLATE_URL" ]; then
        case "$MODE" in
            TProxy) TEMPLATE_URL=$(get_default TPROXY_TEMPLATE_URL) ;;
            TUN) TEMPLATE_URL=$(get_default TUN_TEMPLATE_URL) ;;
            *) echo -e "${RED}未知的模式: $MODE${NC}"; exit 1 ;;
        esac
    fi

    echo -e "${CYAN}你输入的配置信息如下:${NC}"
    echo "后端地址: $BACKEND_URL"
    echo "订阅地址: $SUBSCRIPTION_URL"
    echo "配置文件地址: $TEMPLATE_URL"
    read -rp '确认输入的配置信息？(y/n): ' confirm_choice
    [[ "$confirm_choice" =~ ^[Yy]$ ]] || { echo -e "${RED}请重新输入配置信息。${NC}"; continue; }

    if [ -n "$BACKEND_URL" ] && ! valid_url "$BACKEND_URL"; then echo -e "${RED}后端地址必须是 HTTPS URL。${NC}"; continue; fi
    if [ -n "$TEMPLATE_URL" ] && ! valid_url "$TEMPLATE_URL"; then echo -e "${RED}配置文件地址必须是 HTTPS URL。${NC}"; continue; fi
    if ! valid_subscription "$SUBSCRIPTION_URL"; then echo -e "${RED}订阅地址包含非法字符（空白、# 或 &file=）。${NC}"; continue; fi
    if [ -n "$BACKEND_URL" ] && [ -z "$SUBSCRIPTION_URL" ]; then echo -e "${RED}使用后端地址时订阅地址不能为空。${NC}"; continue; fi

    acquire_lock
    install -d -o root -g root -m 0755 /etc/sing-box
    tmp_manual=$(mktemp /etc/sing-box/.manual.conf.XXXXXX)
    tmp_config=$(mktemp /etc/sing-box/.config.json.XXXXXX)
    backup_manual=$(mktemp /etc/sing-box/.manual.conf.backup.XXXXXX)
    backup_config=$(mktemp /etc/sing-box/.config.json.backup.XXXXXX)
    download_status=$(mktemp /tmp/sbshell-config-status.XXXXXX)
    download_http=$(mktemp /tmp/sbshell-config-http.XXXXXX)
    TMP_FILES+=("$tmp_manual" "$tmp_config" "$backup_manual" "$backup_config" "$download_status" "$download_http")
    rm -f "$download_status" "$download_http"
    manual_existed=0
    config_existed=0

    printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TEMPLATE_URL" > "$tmp_manual"
    if [ -f "$MANUAL_FILE" ]; then install -o root -g root -m 0600 "$MANUAL_FILE" "$backup_manual"; manual_existed=1; fi

    if [ -n "$BACKEND_URL" ] && [ -n "$SUBSCRIPTION_URL" ]; then
        FULL_URL="${BACKEND_URL%/}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"
    else
        FULL_URL="$TEMPLATE_URL"
    fi
    valid_url "$FULL_URL" || { echo -e "${RED}生成的订阅 URL 无效。${NC}" >&2; exit 1; }

    (
        # 真机踩坑（ImmortalWrt 25.12.2）：本脚本是 set -Eeuo pipefail，裸 curl 失败时
        # errexit 会直接干掉整个子 shell，下面写状态文件的那句永远执行不到 —— 父进程
        # 只能空转到 30 秒，把后端返回的 HTTP 500 误报成"配置文件下载超时"。必须用
        # `|| rc=$?` 兜住退出码，并在子 shell 结尾显式 exit 0。
        rc=0
        # 只允许 HTTPS：配置文件内含节点凭据，明文 HTTP 会在链路上泄露（与 debian 侧一致）。
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 -w '%{http_code}' "$FULL_URL" -o "$tmp_config" > "$download_http" || rc=$?
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
        echo -e "${RED}配置文件下载超时（30s），未修改现有配置。${NC}" >&2
        exit 1
    fi
    wait "$curl_pid" 2>/dev/null || true
    download_rc=$(cat "$download_status" 2>/dev/null || echo 1)
    if [ "$download_rc" -ne 0 ]; then
        http_code=$(cat "$download_http" 2>/dev/null || true)
        printf '\n'
        echo -e "${RED}配置文件下载失败，未修改现有配置。${NC}" >&2
        echo -e "${RED}失败原因: $(download_failure_reason "$download_rc" "$http_code")${NC}" >&2
        echo -e "${RED}请求地址: $FULL_URL${NC}" >&2
        exit 1
    fi
    printf '\r配置文件下载中，超时倒计时: 00s\n'
    [ -s "$tmp_config" ] || { echo -e "${RED}下载的配置为空。${NC}" >&2; exit 1; }
    sing-box check -c "$tmp_config" || { echo -e "${RED}配置文件验证失败，未修改现有配置。${NC}" >&2; exit 1; }

    if [ -f "$CONFIG_FILE" ]; then install -o root -g root -m 0600 "$CONFIG_FILE" "$backup_config"; config_existed=1; fi
    chown root:root "$tmp_manual" "$tmp_config"
    chmod 0600 "$tmp_manual"; chmod 0600 "$tmp_config"

    mv -f "$tmp_manual" "$MANUAL_FILE"
    if ! mv -f "$tmp_config" "$CONFIG_FILE"; then
        if [ "$manual_existed" -eq 1 ]; then install -o root -g root -m 0600 "$backup_manual" "$MANUAL_FILE"; else rm -f "$MANUAL_FILE"; fi
        if [ "$config_existed" -eq 1 ]; then install -o root -g root -m 0600 "$backup_config" "$CONFIG_FILE"; else rm -f "$CONFIG_FILE"; fi
        echo -e "${RED}配置文件提交失败，已回滚。${NC}" >&2
        exit 1
    fi
    echo '配置文件下载并验证成功，manual.conf 与 config.json 已事务提交。'
    break
done
