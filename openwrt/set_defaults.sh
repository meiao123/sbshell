#!/bin/bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
DEFAULTS_FILE=/etc/sing-box/defaults.conf
install -d -m 0755 /etc/sing-box
get_default() { awk -F= -v k="$1" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$DEFAULTS_FILE" 2>/dev/null || true; }
valid_url() { [[ "$1" =~ ^https://[^[:space:]]+$ ]]; }

read -rp "请输入后端地址: " BACKEND_URL; BACKEND_URL=${BACKEND_URL:-$(get_default BACKEND_URL)}
read -rp "请输入订阅地址: " SUBSCRIPTION_URL; SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$(get_default SUBSCRIPTION_URL)}
read -rp "请输入TProxy配置文件地址: " TPROXY_TEMPLATE_URL; TPROXY_TEMPLATE_URL=${TPROXY_TEMPLATE_URL:-$(get_default TPROXY_TEMPLATE_URL)}
read -rp "请输入TUN配置文件地址: " TUN_TEMPLATE_URL; TUN_TEMPLATE_URL=${TUN_TEMPLATE_URL:-$(get_default TUN_TEMPLATE_URL)}

for value in "$BACKEND_URL" "$TPROXY_TEMPLATE_URL" "$TUN_TEMPLATE_URL"; do
    [ -z "$value" ] || valid_url "$value" || { echo '所有配置 URL 必须使用 HTTPS。' >&2; exit 1; }
done
[ -n "$SUBSCRIPTION_URL" ] || { echo '订阅地址不能为空。' >&2; exit 1; }

tmp=$(mktemp /tmp/sbshell-defaults.XXXXXX)
trap 'rm -f "$tmp"' EXIT
printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTPROXY_TEMPLATE_URL=%s\nTUN_TEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TPROXY_TEMPLATE_URL" "$TUN_TEMPLATE_URL" > "$tmp"
install -m 0600 "$tmp" "$DEFAULTS_FILE"
echo '默认配置已更新。'
