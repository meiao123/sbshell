#!/bin/bash
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
UI_DIR=/etc/sing-box/ui
BACKUP_DIR=/etc/sing-box/ui-backups
CRON_FILE=/etc/crontabs/root
CRON_MARK='# sbshell-ui-auto-update'
UI_LOCK_DIR=/tmp/sbshell-ui.lock
ZASHBOARD_URL=https://github.com/Zephyruso/zashboard/archive/15575961dc84cc614c66c3e9bd20e70b862b6734/gh-pages.zip
METACUBEXD_URL=https://github.com/MetaCubeX/metacubexd/archive/28a9589f6239bbafc24e87bbf5e5b4997fe42e59/gh-pages.zip
YACD_URL=https://github.com/MetaCubeX/Yacd-meta/archive/6945744f5ab10d3d639d6eb76f3a67167da77b34/gh-pages.zip
command -v curl >/dev/null 2>&1 || { opkg update; opkg install curl; }
command -v unzip >/dev/null 2>&1 || { opkg update; opkg install unzip; }
valid_url() { [[ "$1" =~ ^https://[^[:space:]]+$ ]]; }
get_config_url() { sed -n 's/.*"external_ui_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/sing-box/config.json 2>/dev/null | head -n1; }
archive_top() {
    local extract="$1" candidate count=0 top=''
    while IFS= read -r candidate; do
        [ -z "$candidate" ] && continue
        case "$candidate" in
            /*|../*|*/../*|*\\*) echo 'UI 压缩包包含不安全路径。' >&2; return 1 ;;
        esac
        count=$((count + 1))
        [ "$count" -le 10000 ] || { echo 'UI 压缩包条目过多。' >&2; return 1; }
    done < <(unzip -Z1 "$ZIP_FILE")
    unzip -q -o "$ZIP_FILE" -d "$extract"
    find "$extract" -type l -delete
    [ "$(du -sk "$extract" | awk '{print $1}')" -le 204800 ] || { echo 'UI 解压后体积超过 200 MiB。' >&2; return 1; }
    [ "$(find "$extract" -type f | wc -l)" -le 10000 ] || { echo 'UI 文件数量超过限制。' >&2; return 1; }
    for candidate in "$extract"/*; do
        [ -e "$candidate" ] || continue
        [ -d "$candidate" ] || { echo 'UI 压缩包顶层结构无效。' >&2; return 1; }
        [ -z "$top" ] || { echo 'UI 压缩包包含多个顶层目录。' >&2; return 1; }
        top="$candidate"
    done
    [ -n "$top" ] && [ -f "$top/index.html" ] || { echo 'UI 压缩包结构无效。' >&2; return 1; }
    printf '%s\n' "$top"
}
install_ui() {
    local url="$1" tmp top backup
    while ! mkdir "$UI_LOCK_DIR" 2>/dev/null; do sleep 1; done
    cleanup_ui_lock() { rmdir "$UI_LOCK_DIR" 2>/dev/null || true; }
    trap cleanup_ui_lock RETURN
    valid_url "$url" || { echo 'UI 地址必须使用 HTTPS。' >&2; return 1; }
    tmp=$(mktemp -d /tmp/sbshell-ui.XXXXXX)
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/extract" "$BACKUP_DIR"
    ZIP_FILE="$tmp/ui.zip"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 --max-filesize 52428800 "$url" -o "$ZIP_FILE"
    [ "$(wc -c < "$ZIP_FILE")" -le 52428800 ] || { echo 'UI 压缩包超过 50 MiB。' >&2; return 1; }
    top=$(archive_top "$tmp/extract") || return 1
    backup=$(mktemp -d "$BACKUP_DIR/.ui-backup.XXXXXX")
    rm -rf "$backup"
    if [ -d "$UI_DIR" ]; then mv "$UI_DIR" "$backup"; else rmdir "$backup"; backup=''; fi
    if ! mv "$top" "$UI_DIR"; then
        [ -z "$backup" ] || mv "$backup" "$UI_DIR"
        return 1
    fi
    chown -R root:root "$UI_DIR"
    echo 'UI 安装完成。'
}
check_ui() { [ -f "$UI_DIR/index.html" ] && echo 'UI 面板已安装。' || echo 'UI 面板未安装或不完整。'; }
setup_auto_update_ui() {
    local c schedule
    while true; do
        echo '1. 每周一'; echo '2. 每月1号'; read -rp '请选择(1/2，默认1): ' c; c=${c:-1}
        case "$c" in 1) schedule='0 0 * * 1'; break;; 2) schedule='0 0 1 * *'; break;; *) echo '无效选择。';; esac
    done
    cat > /etc/sing-box/update-ui.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail
UI_DIR=/etc/sing-box/ui
BACKUP_DIR=/etc/sing-box/ui-backups
CONFIG_FILE=/etc/sing-box/config.json
LOCK_DIR=/tmp/sbshell-ui.lock
while ! mkdir "$LOCK_DIR" 2>/dev/null; do sleep 1; done
TMP=$(mktemp -d /tmp/sbshell-ui-auto.XXXXXX)
cleanup(){ rm -rf "$TMP"; rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT
mkdir -p "$BACKUP_DIR"
archive_top() {
  local zip="$1" extract="$2" candidate count=0 top=''
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    case "$candidate" in /*|../*|*/../*|*\\*) exit 1;; esac
    count=$((count + 1)); [ "$count" -le 10000 ] || exit 1
  done < <(unzip -Z1 "$zip")
  unzip -q -o "$zip" -d "$extract"
  find "$extract" -type l -delete
  [ "$(du -sk "$extract" | awk '{print $1}')" -le 204800 ] || exit 1
  [ "$(find "$extract" -type f | wc -l)" -le 10000 ] || exit 1
  for candidate in "$extract"/*; do
    [ -e "$candidate" ] || continue
    [ -d "$candidate" ] || exit 1
    [ -z "$top" ] || exit 1
    top="$candidate"
  done
  [ -n "$top" ] && [ -f "$top/index.html" ] || exit 1
  printf '%s\n' "$top"
}
URL=$(sed -n 's/.*"external_ui_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" 2>/dev/null | head -n1)
URL=${URL:-https://github.com/Zephyruso/zashboard/archive/15575961dc84cc614c66c3e9bd20e70b862b6734/gh-pages.zip}
[[ "$URL" =~ ^https://[^[:space:]]+$ ]] || exit 1
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 --max-filesize 52428800 "$URL" -o "$TMP/ui.zip"
top=$(archive_top "$TMP/ui.zip" "$TMP/extract")
backup=$(mktemp -d "$BACKUP_DIR/.ui-backup.XXXXXX"); rm -rf "$backup"
[ ! -d "$UI_DIR" ] || mv "$UI_DIR" "$backup"
if ! mv "$top" "$UI_DIR"; then [ ! -d "$backup" ] || mv "$backup" "$UI_DIR"; exit 1; fi
chown -R root:root "$UI_DIR"
EOF
chmod 0755 /etc/sing-box/update-ui.sh; chown root:root /etc/sing-box/update-ui.sh
touch "$CRON_FILE"
sed -i "/[[:space:]]$CRON_MARK\$/d" "$CRON_FILE"
printf '%s /etc/sing-box/update-ui.sh %s\n' "$schedule" "$CRON_MARK" >> "$CRON_FILE"
chmod 0600 "$CRON_FILE"; chown root:root "$CRON_FILE"
/etc/init.d/cron restart >/dev/null 2>&1 || true
}
while true; do
    echo '1. 默认 UI'; echo '2. zashboard'; echo '3. metacubexd'; echo '4. yacd'; echo '5. 检查 UI'; echo '6. 设置自动更新'; echo '0. 退出'
    read -rp '请选择: ' choice
    case "$choice" in
        1) url=$(get_config_url || true); install_ui "${url:-$ZASHBOARD_URL}"; exit $?;;
        2) install_ui "$ZASHBOARD_URL"; exit $?;;
        3) install_ui "$METACUBEXD_URL"; exit $?;;
        4) install_ui "$YACD_URL"; exit $?;;
        5) check_ui;;
        6) setup_auto_update_ui; echo '自动更新已设置。';;
        0) exit 0;;
        *) echo '无效选择。';;
    esac
done
