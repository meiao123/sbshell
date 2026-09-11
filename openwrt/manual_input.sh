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
valid_url() { [[ "$1" =~ ^https?://[^[:space:]]+$ ]]; }
valid_subscription() {
    local value="$1"
    [ -z "$value" ] && return 0
    case "$value" in
        *[[:space:]]*|*'&file='*|*'#'*) return 1 ;;
    esac
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

    if [ -n "$BACKEND_URL" ] && ! valid_url "$BACKEND_URL"; then echo -e "${RED}后端地址必须是 HTTP 或 HTTPS URL。${NC}"; continue; fi
    if [ -n "$TEMPLATE_URL" ] && ! valid_url "$TEMPLATE_URL"; then echo -e "${RED}配置文件地址必须是 HTTP 或 HTTPS URL。${NC}"; continue; fi
    if ! valid_subscription "$SUBSCRIPTION_URL"; then echo -e "${RED}订阅地址包含非法字符（空白、# 或 &file=）。${NC}"; continue; fi
    if [ -n "$BACKEND_URL" ] && [ -z "$SUBSCRIPTION_URL" ]; then echo -e "${RED}使用后端地址时订阅地址不能为空。${NC}"; continue; fi

    acquire_lock
    install -d -o root -g root -m 0755 /etc/sing-box
    tmp_manual=$(mktemp /etc/sing-box/.manual.conf.XXXXXX)
    tmp_config=$(mktemp /etc/sing-box/.config.json.XXXXXX)
    backup_manual=$(mktemp /etc/sing-box/.manual.conf.backup.XXXXXX)
    backup_config=$(mktemp /etc/sing-box/.config.json.backup.XXXXXX)
    TMP_FILES+=("$tmp_manual" "$tmp_config" "$backup_manual" "$backup_config")
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

    curl --fail --silent --show-error --location --proto '=http,https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$FULL_URL" -o "$tmp_config" || { echo -e "${RED}配置文件下载失败，未修改现有配置。${NC}" >&2; exit 1; }
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
