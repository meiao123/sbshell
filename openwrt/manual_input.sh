#!/bin/bash
set -Eeuo pipefail

# 公共实现（install 兜底、URL 校验、锁、原子提交）集中在 lib.sh，避免多处副本漂移。
_sbshell_lib_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$_sbshell_lib_dir/lib.sh" || { echo '缺少 lib.sh，请先在菜单 9 更新脚本。' >&2; exit 1; }

CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

MANUAL_FILE=/etc/sing-box/manual.conf
# DEFAULTS_FILE 不在这里直接引用，但它由 lib.sh 的 resolve_default 读取（依赖调用方变量）。
# shellcheck disable=SC2034
DEFAULTS_FILE=/etc/sing-box/defaults.conf
CONFIG_FILE=/etc/sing-box/config.json
MODE_FILE=/etc/sing-box/mode.conf
LOCK_DIR=/tmp/sbshell-config.lock
DEFAULT_TUN_TEMPLATE_URL="https://raw.githubusercontent.com/meiao123/public/refs/heads/main/singbox/configuration/1.2.x/config_sb_Tun_fakeip.json"
LOCK_TIMEOUT=900

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

# mode.conf 缺失时 sed 会失败，pipefail 下赋值失败会直接终止脚本（一个字都不打印）；
# `|| true` 让 MODE 为空，下面「未知的模式」分支才能给出可诊断的提示。
MODE=$( { sed -n 's/^MODE=//p' "$MODE_FILE" 2>/dev/null || true; } | head -n1)
TMP_FILES=()
cleanup() { local file; for file in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do rm -f "$file" 2>/dev/null || true; done; }
trap cleanup EXIT

while true; do
    read -rp '请输入后端地址(回车使用默认值可留空): ' BACKEND_URL
    BACKEND_URL=${BACKEND_URL:-$(resolve_default BACKEND_URL BACKEND_URL 1)}
    read -rp '请输入订阅地址(回车使用默认值可留空): ' SUBSCRIPTION_URL
    SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$(resolve_default SUBSCRIPTION_URL SUBSCRIPTION_URL 1)}
    read -rp '请输入配置文件地址(回车使用默认值可留空): ' TEMPLATE_URL
    if [ -z "$TEMPLATE_URL" ]; then
        case "$MODE" in
            TProxy) TEMPLATE_URL=$(resolve_default TPROXY_TEMPLATE_URL TEMPLATE_URL 0) ;;
            TUN) TEMPLATE_URL=$(resolve_default TUN_TEMPLATE_URL TEMPLATE_URL 0); TEMPLATE_URL=${TEMPLATE_URL:-$DEFAULT_TUN_TEMPLATE_URL} ;;
            *) echo -e "${RED}未知的模式: $MODE${NC}"; exit 1 ;;
        esac
    fi

    # A-28：校验放在「打印摘要 + 确认 y」之前 —— 旧顺序是先让你确认，再告诉你地址不合法，
    # 于是三个地址得全部重输一遍（真机上就踩到了这个）。
    if [ -n "$BACKEND_URL" ] && ! valid_url "$BACKEND_URL"; then echo -e "${RED}后端地址必须是 http:// 或 https:// 的 URL。${NC}"; continue; fi
    # 模板地址为空时后端拼接会得到 ...&file= 的残缺 URL 并照样去下载，必须与 manual_update 一致直接拒绝。
    if ! valid_url "$TEMPLATE_URL"; then echo -e "${RED}配置文件地址必须是 http:// 或 https:// 的 URL。${NC}"; continue; fi
    if ! valid_subscription "$SUBSCRIPTION_URL"; then echo -e "${RED}订阅地址包含非法字符（空白、# 或 &file=）。${NC}"; continue; fi
    if [ -n "$BACKEND_URL" ] && [ -z "$SUBSCRIPTION_URL" ]; then echo -e "${RED}使用后端地址时订阅地址不能为空。${NC}"; continue; fi

    if [ -n "$BACKEND_URL" ] && [ -n "$SUBSCRIPTION_URL" ]; then
        FULL_URL="${BACKEND_URL%/}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"
    else
        FULL_URL="$TEMPLATE_URL"
    fi
    valid_url "$FULL_URL" || { echo -e "${RED}生成的订阅 URL 无效。${NC}"; continue; }
    warn_plaintext_http "$FULL_URL"

    echo -e "${CYAN}你输入的配置信息如下:${NC}"
    echo "后端地址: $BACKEND_URL"
    echo "订阅地址: $SUBSCRIPTION_URL"
    echo "配置文件地址: $TEMPLATE_URL"
    read -rp '确认输入的配置信息？(y/n): ' confirm_choice
    [[ "$confirm_choice" =~ ^[Yy]$ ]] || { echo -e "${RED}请重新输入配置信息。${NC}"; continue; }

    acquire_lock "$LOCK_DIR" "$LOCK_TIMEOUT" cleanup
    install -d -o root -g root -m 0755 /etc/sing-box
    tmp_manual=$(mktemp /etc/sing-box/.manual.conf.XXXXXX)
    tmp_config=$(mktemp /etc/sing-box/.config.json.XXXXXX)
    backup_manual=$(mktemp /etc/sing-box/.manual.conf.backup.XXXXXX)
    backup_config=$(mktemp /etc/sing-box/.config.json.backup.XXXXXX)
    download_status=$(mktemp /tmp/sbshell-config-status.XXXXXX)
    download_http=$(mktemp /tmp/sbshell-config-http.XXXXXX)
    TMP_FILES+=("$tmp_manual" "$tmp_config" "$backup_manual" "$backup_config" "$download_status" "$download_http")
    # A-26：不要 rm 这两个文件。旧写法先删掉名字再由子 shell 用 `>` 重建，
    # 本地用户可抢先创建同名符号链接，让 root 的写跟随到任意文件；
    # 父进程等的是“状态文件为空”，mktemp 的空文件同样满足，保留它们语义不变。
    manual_existed=0
    config_existed=0

    printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TEMPLATE_URL" > "$tmp_manual"
    if [ -f "$MANUAL_FILE" ]; then install -o root -g root -m 0600 "$MANUAL_FILE" "$backup_manual"; manual_existed=1; fi

    (
        # 真机踩坑（ImmortalWrt 25.12.2）：本脚本是 set -Eeuo pipefail，裸 curl 失败时
        # errexit 会直接干掉整个子 shell，下面写状态文件的那句永远执行不到 —— 父进程
        # 只能空转到 30 秒，把后端返回的 HTTP 500 误报成"配置文件下载超时"。必须用
        # `|| rc=$?` 兜住退出码，并在子 shell 结尾显式 exit 0。
        rc=0
        # A-28：允许 http —— 这里请求的是用户自己的后端，回环/内网后端经常就是 http。
        # 非回环的明文 HTTP 已在上面用 warn_plaintext_http 提示过风险，不再阻断。
        # --max-filesize 10 MiB：异常端点返回超大内容时直接失败（curl 63），不把磁盘写满。
        curl --fail --silent --show-error --location --proto '=http,https' --tlsv1.2 --connect-timeout 10 --max-time 30 --max-filesize 10485760 -w '%{http_code}' "$FULL_URL" -o "$tmp_config" > "$download_http" || rc=$?
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
        echo -e "${RED}请求地址: $(redact_url "$FULL_URL")${NC}" >&2
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
