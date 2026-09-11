#!/bin/bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
UI_DIR=/etc/sing-box/ui
BACKUP_DIR=/var/lib/sing-box/ui-backups
ZASHBOARD_URL=https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip
METACUBEXD_URL=https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip
YACD_URL=https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/gh-pages.zip

install_dependencies() {
    command -v curl >/dev/null 2>&1 || { apt-get update; apt-get install -y curl; }
    command -v unzip >/dev/null 2>&1 || { apt-get update; apt-get install -y unzip; }
}
valid_url() { [[ "$1" =~ ^https://[^[:space:]]+$ ]]; }
get_config_url() {
    [ -s /etc/sing-box/config.json ] || return 1
    sed -n 's/.*"external_ui_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/sing-box/config.json | head -n1
}

install_ui() {
    local url="$1" tmp extract top backup
    valid_url "$url" || { echo 'UI 地址必须使用 HTTPS。' >&2; return 1; }
    tmp=$(mktemp -d /tmp/sbshell-ui.XXXXXX)
    extract="$tmp/extract"
    backup="$BACKUP_DIR/$(date +%Y%m%d%H%M%S).ui"
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$extract" "$BACKUP_DIR"

    echo '正在下载 UI...'
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 "$url" -o "$tmp/ui.zip"
    unzip -q "$tmp/ui.zip" -d "$extract"
    top=$(find "$extract" -mindepth 1 -maxdepth 1 -type d -print -quit)
    [ -n "$top" ] || { echo 'UI 压缩包结构无效。' >&2; return 1; }
    [ -f "$top/index.html" ] || { echo 'UI 压缩包缺少 index.html。' >&2; return 1; }

    install -d -o root -g root -m 0755 /etc/sing-box
    if [ -d "$UI_DIR" ]; then mv "$UI_DIR" "$backup"; fi
    if ! mv "$top" "$UI_DIR"; then
        [ ! -d "$backup" ] || mv "$backup" "$UI_DIR"
        return 1
    fi
    chown -R root:root "$UI_DIR"
    echo "UI 安装完成。"
}

check_ui() {
    if [ -f "$UI_DIR/index.html" ]; then echo 'UI 面板已安装。'; else echo 'UI 面板未安装或不完整。'; fi
}

setup_auto_update_ui() {
    local choice schedule
    while true; do
        echo '1. 每周一'; echo '2. 每月1号'
        read -rp '请选择(1/2，默认1): ' choice
        choice=${choice:-1}
        case "$choice" in 1) schedule='0 0 * * 1'; break;; 2) schedule='0 0 1 * *'; break;; *) echo '无效选择。';; esac
    done
    cat > /etc/sing-box/update-ui.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail
UI_DIR=/etc/sing-box/ui
BACKUP_DIR=/var/lib/sing-box/ui-backups
CONFIG_FILE=/etc/sing-box/config.json
TMP=$(mktemp -d /tmp/sbshell-ui-auto.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$BACKUP_DIR"
URL=$(sed -n 's/.*"external_ui_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n1)
URL=${URL:-https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip}
[[ "$URL" =~ ^https://[^[:space:]]+$ ]] || exit 1
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 "$URL" -o "$TMP/ui.zip"
unzip -q "$TMP/ui.zip" -d "$TMP/extract"
TOP=$(find "$TMP/extract" -mindepth 1 -maxdepth 1 -type d -print -quit)
[ -n "$TOP" ] && [ -f "$TOP/index.html" ] || exit 1
BACKUP="$BACKUP_DIR/$(date +%Y%m%d%H%M%S).ui"
[ ! -d "$UI_DIR" ] || mv "$UI_DIR" "$BACKUP"
if ! mv "$TOP" "$UI_DIR"; then
    [ ! -d "$BACKUP" ] || mv "$BACKUP" "$UI_DIR"
    exit 1
fi
chown -R root:root "$UI_DIR"
EOF
chmod 0755 /etc/sing-box/update-ui.sh
chown root:root /etc/sing-box/update-ui.sh
printf 'SHELL=/bin/sh\nPATH=/usr/sbin:/usr/bin:/sbin:/bin\n%s root /etc/sing-box/update-ui.sh\n' "$schedule" > /etc/cron.d/sbshell-ui
chmod 0644 /etc/cron.d/sbshell-ui
chown root:root /etc/cron.d/sbshell-ui
systemctl restart cron
}

install_dependencies
while true; do
    echo '1. 默认 UI（依据配置文件）'; echo '2. zashboard'; echo '3. metacubexd'; echo '4. yacd'; echo '5. 检查 UI'; echo '6. 设置自动更新'; echo '0. 退出'
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
