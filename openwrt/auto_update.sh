#!/bin/bash
set -Eeuo pipefail
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
MANUAL_FILE=/etc/sing-box/manual.conf
CONFIG_FILE=/etc/sing-box/config.json
LOCK_DIR=/tmp/sbshell-config.lock
LOCK_TIMEOUT=900
acquire_lock() {
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then sleep 1; continue; fi
    now=$(date +%s); created=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
    if [ "$created" -gt 0 ] && [ $((now - created)) -ge "$LOCK_TIMEOUT" ]; then rm -rf "$LOCK_DIR"; continue; fi
    sleep 1
done
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"; rm -rf "$TMP"' EXIT INT TERM
}
acquire_lock
TMP=$(mktemp -d /tmp/sbshell-auto.XXXXXX)
read_value() { sed -n "s/^$1=//p" "$MANUAL_FILE" | head -n1; }
B=$(read_value BACKEND_URL); S=$(read_value SUBSCRIPTION_URL); T=$(read_value TEMPLATE_URL)
case "$B" in https://*) ;; *) echo '无效的后端 HTTPS 地址。' >&2; exit 1;; esac
case "$T" in https://*) ;; *) echo '无效的模板 HTTPS 地址。' >&2; exit 1;; esac
[ -n "$S" ] || { echo '订阅地址不能为空。' >&2; exit 1; }
U="${B%/}/config/${S}&file=${T}"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$U" -o "$TMP/config.json"
[ -s "$TMP/config.json" ] || { echo '下载的配置为空。' >&2; exit 1; }
sing-box check -c "$TMP/config.json"
[ ! -f "$CONFIG_FILE" ] || cp -a "$CONFIG_FILE" "$TMP/config.backup"
install -o root -g root -m 0644 "$TMP/config.json" "$CONFIG_FILE"
if ! /etc/init.d/sing-box restart || ! sleep 2 || ! pidof sing-box >/dev/null 2>&1; then
    [ ! -f "$TMP/config.backup" ] || install -o root -g root -m 0644 "$TMP/config.backup" "$CONFIG_FILE"
    /etc/init.d/sing-box restart || true
    exit 1
fi
EOF
chmod 0755 "$UPDATE_SCRIPT"; chown root:root "$UPDATE_SCRIPT"

while true; do
    echo '1. 设置自动更新间隔'; echo '2. 取消自动更新'
    read -rp '请选择(1/2): ' c
    case "$c" in
        1)
            read -rp '间隔小时(1-23,默认12): ' h
            h=${h:-12}
            case "$h" in 1|2|3|4|5|6|7|8|9|1[0-9]|2[0-3]) ;; *) echo -e "${RED}请输入 1-23。${NC}"; continue;; esac
            touch "$CRON_FILE"
            sed -i "/[[:space:]]$CRON_MARK\$/d" "$CRON_FILE"
            printf '0 */%s * * * %s %s\n' "$h" "$UPDATE_SCRIPT" "$CRON_MARK" >> "$CRON_FILE"
            chmod 0600 "$CRON_FILE"; chown root:root "$CRON_FILE"
            /etc/init.d/cron restart >/dev/null 2>&1 || true
            echo -e "${GREEN}已设置，每 $h 小时执行一次。${NC}"; break
            ;;
        2)
            [ -f "$CRON_FILE" ] && sed -i "/[[:space:]]$CRON_MARK\$/d" "$CRON_FILE"
            /etc/init.d/cron restart >/dev/null 2>&1 || true
            echo -e "${GREEN}已取消。${NC}"; break
            ;;
        *) echo -e "${RED}无效选择。${NC}" ;;
    esac
done
