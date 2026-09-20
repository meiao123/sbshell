#!/bin/bash
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo -e "\033[0;31m请以 root 运行。\033[0m" >&2; exit 1; }
UI_DIR=/etc/sing-box/ui
BACKUP_DIR=/etc/sing-box/ui-backups
CRON_FILE=/etc/crontabs/root
CRON_MARK='# sbshell-ui-auto-update'
UI_LOCK_DIR=/tmp/sbshell-ui.lock
LOCK_TIMEOUT=900
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'
ZASHBOARD_URL=https://github.com/Zephyruso/zashboard/archive/15575961dc84cc614c66c3e9bd20e70b862b6734/gh-pages.zip
METACUBEXD_URL=https://github.com/MetaCubeX/metacubexd/archive/28a9589f6239bbafc24e87bbf5e5b4997fe42e59/gh-pages.zip
YACD_URL=https://github.com/MetaCubeX/Yacd-meta/archive/6945744f5ab10d3d639d6eb76f3a67167da77b34/gh-pages.zip
# OpenWrt 25.12 起用 apk 取代了 opkg（ImmortalWrt 25.x 同源）。旧代码只认 opkg：
# 在 apk 固件上缺 unzip/zipinfo 时 `opkg update` 会以 127 退出，set -e 直接把整个
# UI 更新器带走（菜单 10 与 cron 自动更新都走这里）。
if command -v opkg >/dev/null 2>&1; then
    pkg_update() { opkg update; }
    pkg_install() { opkg install "$@"; }
elif command -v apk >/dev/null 2>&1; then
    pkg_update() { apk update; }
    pkg_install() { apk add "$@"; }
else
    pkg_update() { echo '未找到 opkg 或 apk 包管理器。' >&2; return 1; }
    pkg_install() { echo '未找到 opkg 或 apk 包管理器。' >&2; return 1; }
fi
# 依赖探测下沉到真正使用点（A-13）：旧写法在脚本顶层无条件探测 zipinfo/unzip，只要设备上
# 没有 zipinfo，**每次**进入菜单 10（哪怕只是「检查 UI」）都会先跑一次 `opkg update` 网络
# 往返，而且 `pkg_update && pkg_install …` 是行尾命令，失败会被 set -e 直接带走整个脚本。
ensure_curl() {
    command -v curl >/dev/null 2>&1 && return 0
    { pkg_update && pkg_install curl; } || true
    command -v curl >/dev/null 2>&1 || { echo -e "${RED}缺少 curl，无法下载 UI。${NC}" >&2; return 1; }
}
# 只在实际解析压缩包时按需安装；zipinfo 不再是必需项（见 validate_archive 的 unzip -Z 回退）。
ensure_unzip() {
    command -v unzip >/dev/null 2>&1 && return 0
    { pkg_update && pkg_install unzip; } || true
    command -v unzip >/dev/null 2>&1
}
if ! command -v curl >/dev/null 2>&1; then ensure_curl || exit 1; fi
valid_url() { [[ "$1" =~ ^https://[^[:space:]]+$ ]]; }
get_config_url() { sed -n 's/.*"external_ui_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/sing-box/config.json 2>/dev/null | head -n1; }
release_ui_lock() {
    [ -d "$UI_LOCK_DIR" ] || return 0
    owner=$(cat "$UI_LOCK_DIR/pid" 2>/dev/null || true)
    [ "$owner" = "$$" ] && rm -rf "$UI_LOCK_DIR"
}
acquire_ui_lock() {
        waited=0
        while ! mkdir "$UI_LOCK_DIR" 2>/dev/null; do
            owner=$(cat "$UI_LOCK_DIR/pid" 2>/dev/null || true)
            case "$owner" in ''|*[!0-9]*) owner='' ;; esac
            now=$(date +%s)
            created=$(stat -c %Y "$UI_LOCK_DIR" 2>/dev/null || echo 0)
            age=0
            [ "$created" -gt 0 ] && age=$((now - created))
            if [ "$age" -ge "$LOCK_TIMEOUT" ]; then
                rm -rf "$UI_LOCK_DIR" 2>/dev/null || true
                sleep 1
                continue
            fi
            if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
                waited=$((waited + 1))
                if [ "$waited" -ge "$LOCK_TIMEOUT" ]; then
                    echo -e "${RED}等待 UI 更新锁超时（另一个进程持锁）。${NC}" >&2
                    return 1
                fi
            fi
            sleep 1
        done
        printf '%s\n' "$$" > "$UI_LOCK_DIR/pid"
        trap 'release_ui_lock' EXIT
        trap 'release_ui_lock; exit 1' INT TERM
    }
validate_archive() {
    local zip="$1" mode size total=0 count=0 entry list
    # 先按需安装/探测 unzip，再解析清单：本函数第一件事就是 `unzip -Z1`，旧顺序会在缺 unzip
    # 的固件上直接 return 1，永远走不到下面那段按需安装 —— 等于 A-13 根本没生效
    # （行为测试抓到的真实缺陷：断言"缺 unzip 时必须 apk add unzip"一直不成立）。
    if ! command -v unzip >/dev/null 2>&1; then
        ensure_unzip || { echo -e "${RED}缺少 unzip，无法校验 UI 压缩包。${NC}" >&2; return 1; }
    fi
    list=$(mktemp) || { echo -e "${RED}无法创建临时文件。${NC}" >&2; return 1; }
    if ! unzip -Z1 "$zip" > "$list" 2>/dev/null; then
        echo -e "${RED}UI 压缩包无法解析。${NC}" >&2; rm -f "$list"; return 1
    fi
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "$entry" in
            /*|../*|*/../*|*\\*) echo -e "${RED}UI 压缩包包含不安全路径。${NC}" >&2; rm -f "$list"; return 1;;
        esac
        count=$((count + 1))
        [ "$count" -le 10000 ] || { echo -e "${RED}UI 压缩包条目过多。${NC}" >&2; rm -f "$list"; return 1; }
    done < "$list"
    [ "$count" -gt 0 ] || { echo -e "${RED}UI 压缩包为空或无法解析。${NC}" >&2; rm -f "$list"; return 1; }
    # `unzip -Z -l` 与 `zipinfo -l` 输出相同，而且它们本来就是同一个二进制——OpenWrt 的
    # unzip 包不一定提供 /usr/bin/zipinfo，旧代码会在"刚确认安装过 unzip"之后仍然拒绝
    # 安装 UI（用户看到互相矛盾的提示）。两者都不可用才算失败。
    if ! unzip -Z -l "$zip" > "$list" 2>/dev/null; then
        if ! zipinfo -l "$zip" > "$list" 2>/dev/null; then
            echo -e "${RED}UI 压缩包无法解析，请确认已安装 unzip。${NC}" >&2; rm -f "$list"; return 1
        fi
    fi
    while read -r mode size; do
        [ -n "$mode" ] || continue
        case "$mode" in l*|b*|c*|p*) echo -e "${RED}UI 压缩包包含不安全的链接或设备条目。${NC}" >&2; rm -f "$list"; return 1;; esac
        case "$size" in ''|*[!0-9]*) echo -e "${RED}无法解析 UI 压缩包展开大小。${NC}" >&2; rm -f "$list"; return 1;; esac
        total=$((total + size))
        [ "$total" -le 209715200 ] || { echo -e "${RED}UI 压缩包展开后超过 200 MiB。${NC}" >&2; rm -f "$list"; return 1; }
    done < <(awk '$1 ~ /^[-dlcbp]/ {print $1, $4}' "$list")
    rm -f "$list"
    return 0
}
archive_top() {
    local zip="$1" extract="$2" candidate top=''
    validate_archive "$zip" || return 1
    unzip -q -o "$zip" -d "$extract" || { echo -e "${RED}UI 压缩包解压失败。${NC}" >&2; return 1; }
    find "$extract" -type l -exec rm -f {} +
    [ "$(du -sk "$extract" | awk '{print $1}')" -le 204800 ] || { echo -e "${RED}UI 解压后体积超过 200 MiB。${NC}" >&2; return 1; }
    [ "$(find "$extract" -type f | wc -l)" -le 10000 ] || { echo -e "${RED}UI 文件数量超过限制。${NC}" >&2; return 1; }
    for candidate in "$extract"/*; do
        [ -e "$candidate" ] || continue
        [ -d "$candidate" ] || { echo -e "${RED}UI 压缩包顶层结构无效。${NC}" >&2; return 1; }
        [ -z "$top" ] || { echo -e "${RED}UI 压缩包包含多个顶层目录。${NC}" >&2; return 1; }
        top="$candidate"
    done
    [ -n "$top" ] && [ -f "$top/index.html" ] || { echo -e "${RED}UI 压缩包结构无效。${NC}" >&2; return 1; }
    printf '%s\n' "$top"
}
prune_backups() {
    local i; backups=$(ls -1dt "$BACKUP_DIR"/.ui-backup.* 2>/dev/null || true); i=0
    for backup in $backups; do i=$((i + 1)); [ "$i" -le 3 ] || rm -rf -- "$backup"; done
}
# 面板可达性检查（真机踩坑，2026-09-11）：
#   experimental.clash_api.external_ui 是 sing-box **启动时**解析的，所以「UI 文件装好了」
#   不等于「面板能打开」——运行中的实例不会挂载后来才出现的目录，真机表现就是菜单报
#   「UI 安装完成。」但浏览器打开是连接被拒/404，直到手动 /etc/init.d/sing-box restart。
#   安装器此前从不重启、也不校验，只按「文件已复制」报成功（面板还打不开却告诉用户成功）。
# 这里改为：部署后按配置探测本机面板，必要时重启一次服务再确认，仍不通就明确告警。
SINGBOX_INITD=/etc/init.d/sing-box
CONFIG_FILE=/etc/sing-box/config.json

config_value() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -n1; }

# 打印本机探测 URL（http://<host>:<port>/ui/index.html）。
# 返回 1 表示配置里没有可用的 external_controller/external_ui，或 external_ui 不指向本目录
# ——面板由别处提供时我们不该替用户重启 sing-box。
ui_panel_url() {
    local cc ui_path host port
    cc=$(config_value external_controller)
    ui_path=$(config_value external_ui)
    [ -n "$cc" ] && [ -n "$ui_path" ] || return 1
    [ "$ui_path" = "$UI_DIR" ] || return 1
    case "$cc" in
        *:*) host="${cc%:*}"; port="${cc##*:}" ;;
        *)   host="$cc"; port=9090 ;;
    esac
    case "$host" in ''|0.0.0.0|'::'|'[::]') host=127.0.0.1 ;; esac
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    printf 'http://%s:%s/ui/index.html\n' "$host" "$port"
}

# 探测结果（A-06）：
#   0 = 面板真的在服务（HTTP 2xx）—— 这才叫"可达"
#   1 = 连不上/无应答（curl 没给出状态码，或 000）
#   2 = 配置里没有可用的 external_controller/external_ui，无法自动判定
#   3 = 服务在监听，但**没有提供面板**（404/5xx/401…），状态码放进 UI_PANEL_HTTP_CODE
# 旧实现把任何非 000 的状态码都当"可达"：真 curl 不带 --fail 时对 404 返回 0，于是
# "UI 路由没挂上"会被判成安装成功；而测试桩把 404 建模成 exit 22，正好掩盖了这个差异。
ui_panel_reachable() {
    local url code
    UI_PANEL_HTTP_CODE=''
    url=$(ui_panel_url) || return 2
    code=$(curl --silent --show-error --location --proto '=http,https' \
        --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || true
    case "$code" in
        ''|000) return 1 ;;
        2*) return 0 ;;
        *) UI_PANEL_HTTP_CODE="$code"; return 3 ;;
    esac
}

# 判不出 pidof 时按「在运行」处理：面板不可达时重启才是正确动作。
singbox_running() {
    command -v pidof >/dev/null 2>&1 || return 0
    pidof sing-box >/dev/null 2>&1
}

restart_singbox() {
    [ -x "$SINGBOX_INITD" ] || return 1
    local err rc
    err=$(mktemp /tmp/sbshell-ui-restart.XXXXXX 2>/dev/null || echo "/tmp/sbshell-ui-restart.$$")
    if "$SINGBOX_INITD" restart 2>"$err"; then rc=0; else rc=$?; fi
    # procd/rc.common 在没有已注册实例时会回显 ubus 噪音，与 install_singbox.sh 同一套过滤。
    sed '/^Command failed:.*Not found/d' "$err" >&2
    rm -f "$err"
    return "$rc"
}

# 只有确认面板在响应（或确认无法自动探测）才报成功；不可达时重启一次再确认，
# 仍不可达就给出 URL 与下一步，而不是继续打印一句「安装完成」了事。
notify_ui_ready() {
    local url i=0 st=0
    if url=$(ui_panel_url); then
        ui_panel_reachable || st=$?
        if [ "$st" -eq 0 ]; then
            echo -e "${GREEN}UI 安装完成。${NC}"
            return 0
        fi
        if ! singbox_running; then
            echo -e "${GREEN}UI 安装完成。${NC}"
            echo -e "${YELLOW}提示：sing-box 当前未运行，启动后即可访问面板（$url）。${NC}"
            return 0
        fi
        if [ "$st" -eq 3 ]; then
            echo -e "${YELLOW}服务在监听但没有提供面板（HTTP ${UI_PANEL_HTTP_CODE}），正在重启 sing-box 以挂载 /ui 静态路由...${NC}"
        else
            echo -e "${YELLOW}面板尚未响应，正在重启 sing-box 以挂载 /ui 静态路由...${NC}"
        fi
        restart_singbox || true
        while [ "$i" -lt 3 ]; do
            sleep 1
            st=0
            ui_panel_reachable || st=$?
            if [ "$st" -eq 0 ]; then
                echo -e "${GREEN}UI 安装完成（已重启 sing-box，面板已就绪）。${NC}"
                return 0
            fi
            i=$((i + 1))
        done
        echo -e "${GREEN}UI 安装完成。${NC}"
        if [ "$st" -eq 3 ]; then
            echo -e "${RED}但面板仍未响应：$url（HTTP ${UI_PANEL_HTTP_CODE}：服务在监听，但没有提供面板）${NC}" >&2
            echo -e "${YELLOW}请确认 external_ui 指向的目录里确实有 index.html；若用局域网浏览器访问，还要确认 external_controller 不是 127.0.0.1（仅监听本机时局域网打不开面板）。${NC}" >&2
        else
            echo -e "${RED}但面板仍未响应：$url${NC}" >&2
            echo -e "${YELLOW}请查日志：logread | grep sing-box；若你用局域网浏览器访问，还要确认配置里的 external_controller 不是 127.0.0.1（仅监听本机时局域网打不开面板）。${NC}" >&2
        fi
        return 0
    fi
    echo -e "${GREEN}UI 安装完成。${NC}"
    echo -e "${YELLOW}提示：配置里没有可用的 external_controller/external_ui，无法自动确认面板是否可访问。${NC}"
    return 0
}
install_ui() {
    local url="$1" tmp top backup failed_ui staging
    acquire_ui_lock
    valid_url "$url" || { echo -e "${RED}UI 地址必须使用 HTTPS。${NC}" >&2; return 1; }
    tmp=$(mktemp -d /tmp/sbshell-ui.XXXXXX) || { echo -e "${RED}无法创建 UI 临时目录（/tmp 是否可写？）。${NC}" >&2; return 1; }
    staging="${UI_DIR}.staging"
    cleanup_ui_tmp() {
        [ -n "${tmp:-}" ] && rm -rf "$tmp"
        rm -rf "$staging"
        return 0
    }
    mkdir -p "$BACKUP_DIR" || { echo -e "${RED}无法创建 UI 临时目录。${NC}" >&2; cleanup_ui_tmp; return 1; }
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 --max-filesize 52428800 "$url" -o "$tmp/ui.zip"; then
        echo -e "${RED}UI 压缩包下载失败。${NC}" >&2; cleanup_ui_tmp; return 1
    fi
    [ "$(wc -c < "$tmp/ui.zip")" -le 52428800 ] || { echo -e "${RED}UI 压缩包超过 50 MiB。${NC}" >&2; cleanup_ui_tmp; return 1; }
    # 解包必须落在目标文件系统上（$tmp 在 /tmp），否则部署是一次跨设备 mv：
    # 既不是原子 rename，失败回滚时还会把旧 UI 移进半成品目录。
    rm -rf "$staging"
    mkdir -p "$staging/extract" || { cleanup_ui_tmp; return 1; }
    top=$(archive_top "$tmp/ui.zip" "$staging/extract") || { cleanup_ui_tmp; return 1; }
    backup=$(mktemp -d "$BACKUP_DIR/.ui-backup.XXXXXX") || { echo -e "${RED}无法创建 UI 备份目录。${NC}" >&2; cleanup_ui_tmp; return 1; }
    rm -rf "$backup"
    if [ -d "$UI_DIR" ]; then
        mv "$UI_DIR" "$backup" || { echo -e "${RED}备份当前 UI 失败。${NC}" >&2; cleanup_ui_tmp; return 1; }
    else
        backup=''
    fi
    if ! mv "$top" "$UI_DIR"; then
        # 先清掉半成品目标：mv 目标已存在时会把备份移"进"目录里，旧 UI 会变成
        # $UI_DIR/.ui-backup.XXXXXX 而路径上留下半成品。
        rm -rf "$UI_DIR"
        # A-25：旧写法把恢复命令放在 `A || B` 的 B 位（B 是列表最后一条命令），恢复失败
        # 会触发 errexit，下面的告警与 cleanup_ui_tmp 都执行不到。改成显式 if，
        # 两种故障各有明确的告警（注释不照抄旧写法，以免被否定断言命中）。
        if [ -n "$backup" ] && ! mv "$backup" "$UI_DIR"; then
            echo -e "${RED}部署新 UI 失败，且旧 UI 恢复也失败，请手工检查 $backup。${NC}" >&2
        else
            echo -e "${RED}部署新 UI 失败，已恢复旧 UI。${NC}" >&2
        fi
        cleanup_ui_tmp
        return 1
    fi
    if ! chown -R root:root "$UI_DIR"; then
        failed_ui="$tmp/failed-ui"
        mv "$UI_DIR" "$failed_ui" || true
        if [ -n "$backup" ] && [ -d "$backup" ]; then
            mv "$backup" "$UI_DIR" || true
        fi
        echo -e "${RED}新 UI 权限设置失败，已恢复旧 UI。${NC}" >&2
        cleanup_ui_tmp
        return 1
    fi
    prune_backups
    cleanup_ui_tmp
    notify_ui_ready
}
check_ui() {
    local url
    if [ ! -f "$UI_DIR/index.html" ]; then
        echo -e "${RED}UI 面板未安装或不完整。${NC}" >&2
        return 0
    fi
    echo -e "${GREEN}UI 面板已安装。${NC}"
    if url=$(ui_panel_url); then
        if ui_panel_reachable; then
            echo -e "${GREEN}面板正在响应：$url${NC}"
        else
            echo -e "${RED}但面板当前无响应：$url（可执行 /etc/init.d/sing-box restart 后重试）${NC}" >&2
        fi
    else
        echo -e "${YELLOW}配置里没有可用的 external_controller/external_ui，无法探测面板。${NC}" >&2
    fi
    return 0
}
setup_auto_update_ui() {
    local c schedule
    while true; do
        echo '1. 每周一'; echo '2. 每月1号'; read -rp '请选择(1/2，默认1): ' c; c=${c:-1}
        case "$c" in 1) schedule='0 0 * * 1'; break;; 2) schedule='0 0 1 * *'; break;; *) echo -e "${RED}无效选择。${NC}";; esac
    done
    cat > /etc/sing-box/update-ui.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail
# 生成给 cron 的这份脚本没有交互机会：所有拒绝点都必须把原因写进 cron 日志，
# 否则用户只看到「计划任务跑过」而不知道 UI 为什么没更新。
die() { echo "UI 自动更新失败：$1" >&2; exit 1; }
UI_DIR=/etc/sing-box/ui
BACKUP_DIR=/etc/sing-box/ui-backups
CONFIG_FILE=/etc/sing-box/config.json
LOCK_DIR=/tmp/sbshell-ui.lock
LOCK_TIMEOUT=900
release_ui_lock() {
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
                  die '等待面板更新锁超时（另一个进程正在更新 UI）'
              fi
          fi
          sleep 1
      done
      printf '%s\n' "$$" > "$LOCK_DIR/pid"
      # A-18：$TMP 在 acquire_lock 之后才赋值，而 trap 里引用它 —— 取锁超时会 exit 1，
      # 那时 trap 在 set -u 下自己就会因 unbound 报错。用 ${TMP:-} 保护并显式判空。
      trap 'release_ui_lock; [ -z "${TMP:-}" ] || rm -rf "$TMP"' EXIT
      trap 'release_ui_lock; [ -z "${TMP:-}" ] || rm -rf "$TMP"; exit 1' INT TERM
  }
acquire_lock
TMP=$(mktemp -d /tmp/sbshell-ui-auto.XXXXXX) || { echo '无法创建临时目录（/tmp 是否可写？）。' >&2; exit 1; }
mkdir -p "$BACKUP_DIR"
# cron 路径没有交互机会：缺 unzip 时自己装一次（apk/opkg），装不上再 fail-closed，
# 否则缺 unzip 的设备上自动更新会永久失败（交互路径能装，cron 路径不能）。
ensure_unzip_auto() {
  command -v unzip >/dev/null 2>&1 && return 0
  if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1 || true
    apk add unzip >/dev/null 2>&1 || true
  elif command -v opkg >/dev/null 2>&1; then
    opkg update >/dev/null 2>&1 || true
    opkg install unzip >/dev/null 2>&1 || true
  fi
  command -v unzip >/dev/null 2>&1
}
validate_archive() {
  local zip="$1" entry mode size total=0 count=0 list
  ensure_unzip_auto || { echo '缺少 unzip，无法校验 UI 压缩包。' >&2; exit 1; }
  list=$(mktemp) || die '无法创建临时文件（/tmp 不可写？）'
  unzip -Z1 "$zip" > "$list" 2>/dev/null || { rm -f "$list"; die '压缩包校验未通过（缺少 unzip、含不安全条目/链接，或展开后超过 200 MiB）'; }
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in /*|../*|*/../*|*\\*) rm -f "$list"; die '压缩包校验未通过（缺少 unzip、含不安全条目/链接，或展开后超过 200 MiB）';; esac
    count=$((count + 1)); [ "$count" -le 10000 ] || { rm -f "$list"; die '压缩包校验未通过（缺少 unzip、含不安全条目/链接，或展开后超过 200 MiB）'; }
  done < "$list"
  [ "$count" -gt 0 ] || { rm -f "$list"; die '压缩包校验未通过（缺少 unzip、含不安全条目/链接，或展开后超过 200 MiB）'; }
  # 与交互路径一致（A-13）：unzip -Z -l 与 zipinfo -l 输出相同，而且本来就是同一个二进制；
  # OpenWrt 的 unzip 包不一定提供 zipinfo，旧写法会让 cron 自动更新在那些设备上永远失败。
  unzip -Z -l "$zip" > "$list" 2>/dev/null || zipinfo -l "$zip" > "$list" 2>/dev/null || { rm -f "$list"; die '压缩包校验未通过（缺少 unzip、含不安全条目/链接，或展开后超过 200 MiB）'; }
  while read -r mode size; do
    [ -n "$mode" ] || continue
    case "$mode" in l*|b*|c*|p*) rm -f "$list"; die '压缩包校验未通过（缺少 unzip、含不安全条目/链接，或展开后超过 200 MiB）';; esac
    case "$size" in ''|*[!0-9]*) rm -f "$list"; die '压缩包校验未通过（缺少 unzip、含不安全条目/链接，或展开后超过 200 MiB）';; esac
    total=$((total + size)); [ "$total" -le 209715200 ] || { rm -f "$list"; die '压缩包校验未通过（缺少 unzip、含不安全条目/链接，或展开后超过 200 MiB）'; }
  done < <(awk '$1 ~ /^[-dlcbp]/ {print $1, $4}' "$list")
  rm -f "$list"
}
archive_top() {
  local zip="$1" extract="$2" candidate top=''
  validate_archive "$zip"
  unzip -q -o "$zip" -d "$extract"
  find "$extract" -type l -exec rm -f {} +
  [ "$(du -sk "$extract" | awk '{print $1}')" -le 204800 ] || die '解压结果超过 200 MiB（du 上限）'
  [ "$(find "$extract" -type f | wc -l)" -le 10000 ] || die '解压结果文件数超过 10000'
  for candidate in "$extract"/*; do
    [ -e "$candidate" ] || continue
    [ -d "$candidate" ] || die '压缩包顶层目录结构异常（不是目录）'
    [ -z "$top" ] || die '压缩包包含多个顶层目录，无法确定面板根目录'
    top="$candidate"
  done
  [ -n "$top" ] && [ -f "$top/index.html" ] || die '压缩包顶层目录缺少 index.html（不是可用的面板包）'
  printf '%s\n' "$top"
}
URL=$(sed -n 's/.*"external_ui_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" 2>/dev/null | head -n1)
URL=${URL:-https://github.com/Zephyruso/zashboard/archive/15575961dc84cc614c66c3e9bd20e70b862b6734/gh-pages.zip}
[[ "$URL" =~ ^https://[^[:space:]]+$ ]] || die 'UI 下载地址必须是 HTTPS'
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 --max-filesize 52428800 "$URL" -o "$TMP/ui.zip"
staging="${UI_DIR}.staging"
rm -rf "$staging"
mkdir -p "$staging/extract"
top=$(archive_top "$TMP/ui.zip" "$staging/extract")
backup=$(mktemp -d "$BACKUP_DIR/.ui-backup.XXXXXX"); rm -rf "$backup"
[ ! -d "$UI_DIR" ] || mv "$UI_DIR" "$backup"
if ! mv "$top" "$UI_DIR"; then
  rm -rf "$UI_DIR"
  [ ! -d "$backup" ] || mv "$backup" "$UI_DIR"
  rm -rf "$staging"
  die 'UI 目录替换失败，已尝试恢复旧面板'
fi
rm -rf "$staging"
if ! chown -R root:root "$UI_DIR"; then
  failed_ui="$TMP/failed-ui"
  mv "$UI_DIR" "$failed_ui" || true
  [ ! -d "$backup" ] || mv "$backup" "$UI_DIR" || true
  die 'chown root:root 失败，已尝试恢复旧面板'
fi
i=0; backups=$(ls -1dt "$BACKUP_DIR"/.ui-backup.* 2>/dev/null || true); for backup in $backups; do i=$((i + 1)); [ "$i" -le 3 ] || rm -rf -- "$backup"; done
# 与交互式安装同一原因：external_ui 是 sing-box 启动时解析的，目录在实例启动之后才出现
# （或刚被整体替换）时面板不会响应。这里探测一次并按需重启，否则 cron 更新完面板依旧打不开。
panel_url() {
  cc=$(sed -n 's/.*"external_controller"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" 2>/dev/null | head -n1)
  ui_path=$(sed -n 's/.*"external_ui"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" 2>/dev/null | head -n1)
  [ -n "$cc" ] && [ -n "$ui_path" ] || return 1
  [ "$ui_path" = "$UI_DIR" ] || return 1
  case "$cc" in *:*) host="${cc%:*}"; port="${cc##*:}" ;; *) host="$cc"; port=9090 ;; esac
  case "$host" in ''|0.0.0.0|'::'|'[::]') host=127.0.0.1 ;; esac
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  printf 'http://%s:%s/ui/index.html\n' "$host" "$port"
}
if url=$(panel_url) && pidof sing-box >/dev/null 2>&1; then
  # 只把 2xx 当作"面板可用"（A-06）：真 curl 不带 --fail 时对 404/5xx 也返回 0，旧写法
  # 因此会把"UI 路由没挂上"当成成功，cron 更新完用户照样打不开面板。
  probe=$(curl --silent --show-error --location --proto '=http,https' \
      --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || true
  case "$probe" in
    2*) : ;;
    *)
      /etc/init.d/sing-box restart >/dev/null 2>&1 || true
      sleep 2
      probe=$(curl --silent --location --proto '=http,https' --max-time 5 \
          -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || true
      case "$probe" in
        2*) echo "UI 已更新并已重启 sing-box，面板已就绪。" >&2 ;;
        *)  echo "UI 已更新，但面板仍未响应：$url（HTTP ${probe:-000}）" >&2 ;;
      esac
      ;;
  esac
fi
EOF
chmod 0755 /etc/sing-box/update-ui.sh; chown root:root /etc/sing-box/update-ui.sh
touch "$CRON_FILE"; sed -i "/[[:space:]]$CRON_MARK\$/d" "$CRON_FILE"; printf '%s /etc/sing-box/update-ui.sh %s\n' "$schedule" "$CRON_MARK" >> "$CRON_FILE"; chmod 0600 "$CRON_FILE"; chown root:root "$CRON_FILE"; if ! /etc/init.d/cron restart >/dev/null 2>&1; then
                echo -e "${RED}计划任务未生效：cron 重启失败，请手动执行 /etc/init.d/cron restart。${NC}" >&2
            fi
echo -e "${GREEN}UI 自动更新已设置。${NC}"
}
while true; do
    echo -e "${CYAN}======== Sbshell UI 管理菜单 ========${NC}"
    echo '1. 默认 UI'
    echo '2. zashboard'
    echo '3. metacubexd'
    echo '4. yacd'
    echo '5. 检查 UI'
    echo '6. 设置自动更新'
    echo '0. 退出'
    echo -e "${CYAN}====================================${NC}"
    read -rp '请选择: ' choice
    case "$choice" in
        1) url=$(get_config_url || true); install_ui "${url:-$ZASHBOARD_URL}"; exit $?;;
        2) install_ui "$ZASHBOARD_URL"; exit $?;;
        3) install_ui "$METACUBEXD_URL"; exit $?;;
        4) install_ui "$YACD_URL"; exit $?;;
        5) check_ui;;
        6) setup_auto_update_ui;;
        0) exit 0;;
        *) echo -e "${RED}无效选择。${NC}";;
esac
done
