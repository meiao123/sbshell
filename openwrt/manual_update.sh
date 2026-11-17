#!/bin/bash
set -Eeuo pipefail

# 公共实现（install 兜底、URL 校验、锁、原子提交）集中在 lib.sh，避免多处副本漂移。
_sbshell_lib_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$_sbshell_lib_dir/lib.sh" || { echo '缺少 lib.sh，请先在菜单 9 更新脚本。' >&2; exit 1; }

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
MANUAL_FILE=/etc/sing-box/manual.conf
# DEFAULTS_FILE 不在这里直接引用，但它由 lib.sh 的 resolve_default 读取（依赖调用方变量）。
# shellcheck disable=SC2034
DEFAULTS_FILE=/etc/sing-box/defaults.conf
CONFIG_FILE=/etc/sing-box/config.json
BACKUP_FILE=/etc/sing-box/config.json.bak
MODE_FILE=/etc/sing-box/mode.conf
LOCK_DIR=/tmp/sbshell-config.lock
LOCK_TIMEOUT=900
# 先提权再建临时目录（exec 不触发 EXIT trap）。
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
TMP_DIR=$(mktemp -d /tmp/sbshell-config.XXXXXX) || exit 1
# acquire_lock（lib.sh）会在 EXIT/INT/TERM 里与放锁一起执行本函数，这里不再自设 trap。
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# 下载失败时的可操作提示：后端就在本机却连不上，基本就是容器没起/后端崩了。
hint_local_backend() {
    case "${BACKEND_URL:-}" in
        http://127.0.0.1[:/]*|http://localhost[:/]*|http://\[::1\][:/]*)
            echo -e "${YELLOW}提示：本机后端可能没在运行；可在菜单 12 构建/重建后端（Toperlock/sing-box-subscribe）。${NC}" >&2 ;;
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

MODE=$(read_value MODE "$MODE_FILE")

confirm_yes() {
    local prompt="$1" answer
    while true; do
        # EOF（无 tty / stdin 被关）返回 2，调用方必须与用户答「否」（返回 1）区分开：
        # 旧实现把 EOF 当「否」，于是无人确认也会继续下载并替换配置。
        read -r -p "$prompt [y/n]: " answer || { echo -e "${RED}无法读取输入，操作已取消。${NC}" >&2; return 2; }
        case "$answer" in
            [Yy]) return 0;;
            [Nn]) return 1;;
            *) echo -e "${RED}请输入 y 或 n。${NC}";;
        esac
    done
}

# 默认值解析顺序（defaults.conf 优先、键缺失/为空时回退 manual.conf、nz 参数语义）见
# lib.sh 的 resolve_default：菜单 6 只填了部分字段时，选项 2 直接回车仍能沿用当前生效的地址。
prompt_user_input() {
    local default_backend default_subscription default_template
    while true; do
        # 默认值：已保存值（defaults.conf → manual.conf）> lib.sh 出厂值；选项 2 里直接回显，
        # 回车即用。订阅地址在这里直接回显——本机/局域网后端下没有打码的必要。
        default_backend=$(default_or_factory BACKEND_URL)
        default_subscription=$(default_or_factory SUBSCRIPTION_URL)
        case "$MODE" in
            TProxy) default_template=$(resolve_default TPROXY_TEMPLATE_URL TEMPLATE_URL 0);;
            TUN) default_template=$(resolve_default TUN_TEMPLATE_URL TEMPLATE_URL 0); default_template=${default_template:-$(factory_default TUN_TEMPLATE_URL)};;
            *) default_template='';;
        esac
        read -rp "后端地址(留空使用默认: ${default_backend:-无}): " BACKEND_URL || { echo -e "${RED}无法读取后端地址。${NC}" >&2; return 1; }
        BACKEND_URL=${BACKEND_URL:-$default_backend}
        read -rp "订阅地址(留空使用默认: ${default_subscription:-无}): " SUBSCRIPTION_URL || { echo -e "${RED}无法读取订阅地址。${NC}" >&2; return 1; }
        SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$default_subscription}
        read -rp "配置文件地址(留空使用默认: ${default_template:-无}): " TEMPLATE_URL || { echo -e "${RED}无法读取配置文件地址。${NC}" >&2; return 1; }
        if [ -z "$TEMPLATE_URL" ]; then
            case "$MODE" in
                TProxy|TUN) TEMPLATE_URL=$default_template;;
                *) echo -e "${RED}未知模式，无法从默认值读取配置文件地址。${NC}" >&2; return 1;;
            esac
        fi
        validate_endpoints && return 0
    done
}

CONFIRM_RC=0
confirm_yes '是否重新设置配置文件地址？' || CONFIRM_RC=$?
if [ "$CONFIRM_RC" -eq 2 ]; then
    # 读不到输入时一律不改动配置（不能像旧实现那样按「否」继续下载并替换）。
    exit 1
fi
if [ "$CONFIRM_RC" -eq 1 ]; then
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

acquire_lock "$LOCK_DIR" "$LOCK_TIMEOUT" cleanup
manual_existed=0
# 回滚依据只看「本次是否备份过」，不能用 .bak 是否存在判断（那可能是上次运行遗留的）。
config_existed=0
if [ -f "$MANUAL_FILE" ]; then
    cp -a "$MANUAL_FILE" "$TMP_DIR/manual.backup" || { echo -e "${RED}备份地址配置失败。${NC}" >&2; exit 1; }
    manual_existed=1
fi
if [ -f "$CONFIG_FILE" ]; then cp -a "$CONFIG_FILE" "$BACKUP_FILE" || { echo -e "${RED}旧配置备份失败，已取消更新。${NC}" >&2; exit 1; }; config_existed=1; fi

# 与初始化路径（manual_input.sh）一致：30s 超时 + 实时倒计时。curl 放进后台子 shell 写状态文件，
# 前台显示倒计时；子 shell 内用 `|| rc=$?` 兜住退出码（本脚本是 set -Eeuo pipefail，裸 curl 失败
# 会直接终止子 shell，状态文件永远写不出来，父进程只能空转到超时并误报原因）。
# 失败原因翻译直接复用 lib.sh 的 download_failure_reason（与初始化路径同一份实现）。
download_status=$(mktemp /tmp/sbshell-update-status.XXXXXX)
download_http=$(mktemp /tmp/sbshell-update-http.XXXXXX)
# A-26：不要 rm 这个文件（同名符号链接抢注 + 子 shell `>` 跟随会写到任意文件）；
# 父进程等的是“文件为空”，mktemp 的空文件同样满足，保留它语义不变。
(
    rc=0
    # A-28：允许 http —— 这里请求的是用户自己的后端，回环/内网后端经常就是 http；
    # 非回环的明文 HTTP 已由 warn_plaintext_http 提示风险，不再阻断。
    # -w 把 HTTP 状态码写进单独文件：失败时才能区分 5xx / 401 / 403 / 404。
    # --max-filesize 10 MiB：异常端点返回超大内容时直接失败（curl 63），不把磁盘写满。
    curl --fail --silent --show-error --location --proto '=http,https' --tlsv1.2 --connect-timeout 10 --max-time 30 --max-filesize 10485760 -w '%{http_code}' "$FULL_URL" -o "$TMP_DIR/config.json" > "$download_http" || rc=$?
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
    hint_local_backend
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
    hint_local_backend
    exit 1
fi
printf '\r配置文件下载中，超时倒计时: 00s\n'
if ! sing-box check -c "$TMP_DIR/config.json"; then
    echo -e "${RED}新配置验证失败，已保留之前的 config.json。${NC}" >&2
    exit 1
fi

# 回滚：只恢复本次真正备份过的旧文件，否则删除本次新建的文件 —— 旧写法按 .bak 是否存在判断，
# 会把上一次运行遗留的 config.json.bak 装回去，覆盖掉本来完好的当前配置。
rollback_commit() {
    if [ "$config_existed" -eq 1 ]; then
        install -o root -g root -m 0600 "$BACKUP_FILE" "$CONFIG_FILE" || true
    else
        rm -f "$CONFIG_FILE"
    fi
    if [ "$manual_existed" -eq 1 ]; then
        install -o root -g root -m 0600 "$TMP_DIR/manual.backup" "$MANUAL_FILE" || true
    else
        rm -f "$MANUAL_FILE"
    fi
}

# 原子提交：commit_file（lib.sh）先 install 到同目录临时文件、chmod 0600，再用 mv（rename）
# 替换目标 —— 直接 install 到目标时断电/被杀会留下半截配置，失败路径也要清掉临时文件。
if [ -f "$TMP_DIR/manual.conf" ]; then
    commit_file "$TMP_DIR/manual.conf" "$MANUAL_FILE" 0600 || { echo -e "${RED}新地址保存失败，已保留之前的配置。${NC}" >&2; exit 1; }
fi
commit_file "$TMP_DIR/config.json" "$CONFIG_FILE" 0600 || {
    rollback_commit
    echo -e "${RED}新配置写入失败，已恢复旧配置。${NC}" >&2
    exit 1
}

# 重启沿用仓库其它入口的写法：rc.common/procd 在没有已注册实例时会回显 ubus 的「没有东西可删」
# 噪音，两种形态都要过滤：短形态 `Command failed: Not found`，以及带命令名的长形态
# `Command failed: ubus call service delete { "name": "sing-box" } (Not found)`。
if ! /etc/init.d/sing-box restart 2> >(sed '/^Command failed:.*Not found/d' >&2) || ! sleep 2 || ! pidof sing-box >/dev/null 2>&1; then
    rollback_commit
    /etc/init.d/sing-box restart 2> >(sed '/^Command failed:.*Not found/d' >&2) || true
    echo -e "${RED}新配置启动失败，已恢复旧配置。${NC}" >&2
    exit 1
fi

echo -e "${GREEN}配置更新并启动成功。旧配置已备份到 $BACKUP_FILE。${NC}"
