#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
MANUAL_FILE="/etc/sing-box/manual.conf"
CONFIG_FILE="/etc/sing-box/config.json"
UPDATE_SCRIPT="/etc/sing-box/update-singbox.sh"
CRON_FILE="/etc/cron.d/sbshell-singbox"

[ -r "$MANUAL_FILE" ] || { echo -e "${RED}未找到手动配置文件。${NC}" >&2; exit 1; }

cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
MANUAL_FILE="/etc/sing-box/manual.conf"
CONFIG_FILE="/etc/sing-box/config.json"
CONFIG_DIR="/etc/sing-box"

get_value() { grep -m1 "^$1=" "$MANUAL_FILE" | cut -d'=' -f2-; }
BACKEND_URL=$(get_value BACKEND_URL)
SUBSCRIPTION_URL=$(get_value SUBSCRIPTION_URL)
TEMPLATE_URL=$(get_value TEMPLATE_URL)

if [ -n "$BACKEND_URL" ] && [ -n "$SUBSCRIPTION_URL" ]; then
    FULL_URL="${BACKEND_URL%/}/config/${SUBSCRIPTION_URL}&file=${TEMPLATE_URL}"
else
    FULL_URL="$TEMPLATE_URL"
fi
[[ "$FULL_URL" =~ ^https://[^[:space:]]+$ ]] || { echo "invalid HTTPS config URL" >&2; exit 1; }

tmp=$(mktemp "$CONFIG_DIR/.config.json.XXXXXX")
backup=$(mktemp "$CONFIG_DIR/.config.json.backup.XXXXXX")
cleanup() { rm -f "$tmp" "$backup"; }
trap cleanup EXIT
[ -f "$CONFIG_FILE" ] && cp -p "$CONFIG_FILE" "$backup"

curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$FULL_URL" -o "$tmp" || { echo "config download failed" >&2; exit 1; }
[ -s "$tmp" ] || { echo "downloaded config is empty" >&2; exit 1; }
sing-box check -c "$tmp" || { echo "config validation failed" >&2; exit 1; }
install -o root -g root -m 0644 "$tmp" "$CONFIG_FILE"

if ! systemctl restart sing-box; then
    echo "service restart failed; restoring previous config" >&2
    if [ -s "$backup" ]; then
        install -o root -g root -m 0644 "$backup" "$CONFIG_FILE"
        systemctl restart sing-box || true
    fi
    exit 1
fi
EOF
chmod 0755 "$UPDATE_SCRIPT"
chown root:root "$UPDATE_SCRIPT"

while true; do
    echo -e "${CYAN}请选择操作:${NC}"
    echo "1. 设置自动更新间隔"
    echo "2. 取消自动更新"
    read -rp "请输入选项 (1或2, 默认为1): " menu_choice
    menu_choice=${menu_choice:-1}

    if [[ "$menu_choice" == "1" ]]; then
        while true; do
            read -rp "请输入更新间隔小时数 (1-23小时,默认为12小时): " interval_choice
            interval_choice=${interval_choice:-12}
            if [[ "$interval_choice" =~ ^([1-9]|1[0-9]|2[0-3])$ ]]; then break; fi
            echo -e "${RED}输入无效，请输入1到23之间的小时数。${NC}"
        done
        printf '0 */%s * * * root %s\n' "$interval_choice" "$UPDATE_SCRIPT" | sudo tee "$CRON_FILE" >/dev/null
        sudo chmod 0644 "$CRON_FILE"
        sudo chown root:root "$CRON_FILE"
        sudo systemctl restart cron
        echo -e "${GREEN}定时更新任务已设置，每 $interval_choice 小时执行一次。${NC}"
        break
    elif [[ "$menu_choice" == "2" ]]; then
        sudo rm -f "$CRON_FILE"
        sudo systemctl restart cron
        echo -e "${GREEN}自动更新任务已取消。${NC}"
        break
    else
        echo -e "${RED}输入无效，请输入1或2。${NC}"
    fi
done
