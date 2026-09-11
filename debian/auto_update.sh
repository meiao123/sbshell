#!/bin/bash
set -Eeuo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
SCRIPT_DIR="/etc/sing-box/scripts"
MANUAL_FILE="/etc/sing-box/manual.conf"
UPDATE_SCRIPT="/etc/sing-box/update-singbox.sh"
CRON_FILE="/etc/cron.d/sbshell-singbox"

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
[ -f "$MANUAL_FILE" ] || { echo -e "${RED}未找到 manual.conf，请先配置订阅。${NC}"; exit 1; }

mkdir -p "$SCRIPT_DIR"
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
MANUAL_FILE="/etc/sing-box/manual.conf"
CONFIG_FILE="/etc/sing-box/config.json"
LOCK_FILE="/run/lock/sbshell-config.lock"
install -d -o root -g root -m 0755 /run/lock
exec 9>"$LOCK_FILE"
flock -x 9
TMP_DIR=$(mktemp -d /tmp/sbshell-auto.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT
read_value() { awk -F= -v k="$1" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$2" 2>/dev/null || true; }
valid_url() { [[ "$1" =~ ^https://[^[:space:]]+$ ]]; }
BACKEND_URL=$(read_value BACKEND_URL "$MANUAL_FILE")
SUBSCRIPTION_URL=$(read_value SUBSCRIPTION_URL "$MANUAL_FILE")
TEMPLATE_URL=$(read_value TEMPLATE_URL "$MANUAL_FILE")
valid_url "$BACKEND_URL" && [ -n "$SUBSCRIPTION_URL" ] && valid_url "$TEMPLATE_URL" || exit 1
FULL_URL="${BACKEND_URL%/}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"
TMP_CONFIG="$TMP_DIR/config.json"
BACKUP="$TMP_DIR/config.json.backup"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$FULL_URL" -o "$TMP_CONFIG"
sing-box check -c "$TMP_CONFIG"
[ ! -f "$CONFIG_FILE" ] || cp -a "$CONFIG_FILE" "$BACKUP"
install -o root -g root -m 0644 "$TMP_CONFIG" "$CONFIG_FILE"
if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
    [ ! -f "$BACKUP" ] || install -o root -g root -m 0644 "$BACKUP" "$CONFIG_FILE"
    systemctl restart sing-box || true
    exit 1
fi
EOF
chmod 0755 "$UPDATE_SCRIPT"
chown root:root "$UPDATE_SCRIPT"

while true; do
    echo '1. 设置自动更新间隔'
    echo '2. 取消自动更新'
    read -rp "请输入选项 (1或2, 默认为1): " menu_choice
    menu_choice=${menu_choice:-1}
    case "$menu_choice" in
        1)
            while true; do
                read -rp "请输入更新间隔小时数 (1-23小时,默认为12小时): " interval
                interval=${interval:-12}
                [[ "$interval" =~ ^([1-9]|1[0-9]|2[0-3])$ ]] && break
                echo -e "${RED}请输入 1-23。${NC}"
            done
            printf 'SHELL=/bin/sh\nPATH=/usr/sbin:/usr/bin:/sbin:/bin\n0 */%s * * * root %s\n' "$interval" "$UPDATE_SCRIPT" > "$CRON_FILE"
            chown root:root "$CRON_FILE"; chmod 0644 "$CRON_FILE"
            systemctl restart cron >/dev/null 2>&1 || true
            echo -e "${GREEN}自动更新已设置，每 $interval 小时执行一次。${NC}"
            break
            ;;
        2)
            rm -f "$CRON_FILE"
            systemctl restart cron >/dev/null 2>&1 || true
            echo -e "${GREEN}自动更新已取消。${NC}"
            break
            ;;
        *) echo -e "${RED}输入无效。${NC}" ;;
    esac
done
