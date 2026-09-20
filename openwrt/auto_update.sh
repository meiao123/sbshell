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
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
MANUAL_FILE=/etc/sing-box/manual.conf
UPDATE_SCRIPT=/etc/sing-box/update-singbox.sh
CRON_FILE=/etc/crontabs/root
CRON_MARK='# sbshell-singbox-auto-update'
[ -f "$MANUAL_FILE" ] || { echo '未找到 manual.conf。' >&2; exit 1; }

cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/sh
set -eu



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
MANUAL_FILE=/etc/sing-box/manual.conf
CONFIG_FILE=/etc/sing-box/config.json
# 回滚来源必须放在 $TMP 之外：$TMP 会被 cleanup() 在 EXIT 时 rm -rf，
# 而失败路径上那份备份是唯一的回滚依据（放在 $TMP 里等于退出即销毁）。
BACKUP_FILE=/etc/sing-box/config.json.bak
LOCK_DIR=/tmp/sbshell-config.lock
LOCK_TIMEOUT=900
TMP=$(mktemp -d /tmp/sbshell-auto.XXXXXX)
release_lock() {
  [ -d "$LOCK_DIR" ] || return 0
  owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  [ "$owner" = "$$" ] && rm -rf "$LOCK_DIR"
}
cleanup() { release_lock; rm -rf "$TMP"; }
trap cleanup EXIT
trap 'cleanup; exit 1' INT TERM
acquire_lock() {
  waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    case "$owner" in ''|*[!0-9]*) owner='' ;; esac
    now=$(date +%s); created=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
    age=0; [ "$created" -gt 0 ] && age=$((now - created))
    if [ "$age" -ge "$LOCK_TIMEOUT" ]; then rm -rf "$LOCK_DIR" 2>/dev/null || true; sleep 1; continue; fi
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      waited=$((waited + 1))
      [ "$waited" -lt "$LOCK_TIMEOUT" ] || { echo '等待配置锁超时（另一个进程持锁）。' >&2; return 1; }
    fi
    sleep 1
  done
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}
acquire_lock
read_value() { sed -n "s/^$1=//p" "$MANUAL_FILE" | head -n1; }
B=$(read_value BACKEND_URL); S=$(read_value SUBSCRIPTION_URL); T=$(read_value TEMPLATE_URL)
case "$B" in
    '') U="$T";;
    https://*) [ -n "$S" ] || { echo '使用后端地址时订阅地址不能为空。' >&2; exit 1; }; U="${B%/}/config/${S}&file=${T}";;
    *) echo '无效的后端 HTTPS 地址。' >&2; exit 1;;
esac
case "$S" in *[[:space:]]*|*'&file='*|*'#'*) echo '订阅地址包含非法字符。' >&2; exit 1;; esac
case "$T" in https://*) ;; *) echo '无效的模板 HTTPS 地址。' >&2; exit 1;; esac
case "$U" in https://*) ;; *) echo '生成的订阅 URL 无效。' >&2; exit 1;; esac
# 30s 超时 + 实时倒计时：手动执行本脚本（stdout 是终端）时显示倒计时，cron 里静默不刷日志。
# curl 放进后台子 shell 写状态文件，前台显示倒计时；`|| rc=$?` 兜住退出码（本脚本 set -eu，
# 裸 curl 失败会直接终止子 shell，状态文件写不出来）。
download_status=$(mktemp /tmp/sbshell-auto-status.XXXXXX)
rm -f "$download_status"
(
    rc=0
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 "$U" -o "$TMP/config.json" || rc=$?
    printf '%s\n' "$rc" > "$download_status"
    exit 0
) &
curl_pid=$!
elapsed=0
while [ ! -s "$download_status" ]; do
    if [ -t 1 ]; then
        remaining=$((30 - elapsed))
        [ "$remaining" -ge 0 ] || remaining=0
        printf '\r配置文件下载中，超时倒计时: %02ds' "$remaining"
    fi
    if [ "$elapsed" -ge 30 ]; then
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done
if [ ! -s "$download_status" ]; then
    kill "$curl_pid" 2>/dev/null || true
    wait "$curl_pid" 2>/dev/null || true
    if [ -t 1 ]; then printf '\n'; fi
    echo '配置下载超时（30s）。' >&2
    rm -f "$download_status"
    exit 1
fi
wait "$curl_pid" 2>/dev/null || true
download_rc=$(cat "$download_status" 2>/dev/null || echo 1)
rm -f "$download_status"
if [ -t 1 ]; then printf '\r配置文件下载中，超时倒计时: 00s\n'; fi
[ "$download_rc" -eq 0 ] || { echo '配置下载失败。' >&2; exit 1; }
[ -s "$TMP/config.json" ] || { echo '下载的配置为空。' >&2; exit 1; }
sing-box check -c "$TMP/config.json"
[ ! -f "$CONFIG_FILE" ] || cp -a "$CONFIG_FILE" "$BACKUP_FILE"
# 原子替换：先在同一目录落一份临时文件，再用 mv（同文件系统 rename）替换 config.json。
# 直接写 config.json 时若被中断/断电，会留下半截配置且没有可用的回滚来源，sing-box 起不来。
NEW_CONFIG="$CONFIG_FILE.new.$$"
install -o root -g root -m 0600 "$TMP/config.json" "$NEW_CONFIG" || { echo '写入新配置失败。' >&2; rm -f "$NEW_CONFIG"; exit 1; }
mv -f "$NEW_CONFIG" "$CONFIG_FILE" || { echo '替换配置失败。' >&2; rm -f "$NEW_CONFIG"; exit 1; }
# rc.common/procd 在没有已注册实例时会回显 ubus 噪音（短形态 `Command failed: Not found` 与
# 带命令名的长形态 `Command failed: ubus call service delete { "name": "sing-box" } (Not found)`）。
# 本脚本是 #!/bin/sh（busybox 的 ash 没有进程替换），故用可移植写法过滤，同时保留真实退出码。
restart_singbox() {
    err=$(mktemp /tmp/sbshell-restart.XXXXXX 2>/dev/null || echo "/tmp/sbshell-restart.$$")
    if /etc/init.d/sing-box restart 2>"$err"; then rc=0; else rc=$?; fi
    sed '/^Command failed:.*Not found/d' "$err" >&2
    rm -f "$err"
    return "$rc"
}
if ! restart_singbox || ! sleep 2 || ! pidof sing-box >/dev/null 2>&1; then
    [ ! -f "$BACKUP_FILE" ] || install -o root -g root -m 0600 "$BACKUP_FILE" "$CONFIG_FILE"
    restart_singbox || true
    exit 1
fi
EOF
chmod 0755 "$UPDATE_SCRIPT"; chown root:root "$UPDATE_SCRIPT"

while true; do
    echo '1. 设置自动更新间隔'; echo '2. 取消自动更新'
    read -rp '请选择(1/2): ' c
    case "$c" in
        1)
            read -rp '间隔小时(1/2/3/4/6/8/12,默认12): ' h
            h=${h:-12}
            case "$h" in 1|2|3|4|6|8|12) ;; *) echo -e "${RED}请输入 1/2/3/4/6/8/12。${NC}"; continue;; esac
            touch "$CRON_FILE"
            sed -i "/[[:space:]]$CRON_MARK\$/d" "$CRON_FILE"
            printf '0 */%s * * * %s %s\n' "$h" "$UPDATE_SCRIPT" "$CRON_MARK" >> "$CRON_FILE"
            chmod 0600 "$CRON_FILE"; chown root:root "$CRON_FILE"
            /etc/init.d/cron restart >/dev/null 2>&1 || true
            echo -e "${GREEN}已设置，每 $h 小时执行一次。${NC}"; break;;
        2)
            [ -f "$CRON_FILE" ] && sed -i "/[[:space:]]$CRON_MARK\$/d" "$CRON_FILE"
            /etc/init.d/cron restart >/dev/null 2>&1 || true
            echo -e "${GREEN}已取消。${NC}"; break;;
        *) echo -e "${RED}无效选择。${NC}";;
    esac
done
