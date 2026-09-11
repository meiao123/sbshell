#!/bin/bash
# 生成服务端配置：SS 密码 / VLESS UUID / REALITY 密钥对 / hysteria2 密码全部本地随机生成。
# 仓库模板 config_template/server/config.json 里的凭据是公开的，只适合做字段参考，
# 不能用于真实部署（本脚本就是为了取代“默认下载公开凭据模板”这一行为）。
set -Eeuo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
CONFIG_DIR=/etc/sing-box
CONFIG_FILE="$CONFIG_DIR/config.json"

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
command -v sing-box >/dev/null 2>&1 || { echo -e "${RED}未找到 sing-box，请先安装。${NC}" >&2; exit 1; }
install -d -o root -g root -m 0755 "$CONFIG_DIR"

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

rand_base64() {
    if sing-box generate rand --base64 "$1" 2>/dev/null; then return 0; fi
    head -c "$1" /dev/urandom | base64 | tr -d '\n'
}
rand_hex() {
    if sing-box generate rand --hex "$1" 2>/dev/null; then return 0; fi
    head -c "$1" /dev/urandom | od -An -v -tx1 | tr -d ' \n'
}

read -rp 'SS 监听端口 (默认 80): ' SS_PORT; SS_PORT=${SS_PORT:-80}
valid_port "$SS_PORT" || { echo -e "${RED}SS 端口无效。${NC}" >&2; exit 1; }
read -rp 'VLESS-Vision-REALITY 监听端口 (默认 443): ' VLESS_PORT; VLESS_PORT=${VLESS_PORT:-443}
valid_port "$VLESS_PORT" || { echo -e "${RED}VLESS 端口无效。${NC}" >&2; exit 1; }
read -rp 'REALITY 伪装域名 (默认 updates.cdn-apple.com): ' REALITY_SNI; REALITY_SNI=${REALITY_SNI:-updates.cdn-apple.com}
[[ "$REALITY_SNI" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo -e "${RED}伪装域名格式不正确。${NC}" >&2; exit 1; }

ENABLE_HY2=0; HY2_PORT=''; HY2_CERT=''; HY2_KEY=''
read -rp '是否额外配置 hysteria2？(需要已有证书) [y/N]: ' want_hy2
if [[ "$want_hy2" =~ ^[Yy]$ ]]; then
    read -rp 'hysteria2 监听端口 (默认 52021): ' HY2_PORT; HY2_PORT=${HY2_PORT:-52021}
    valid_port "$HY2_PORT" || { echo -e "${RED}hysteria2 端口无效。${NC}" >&2; exit 1; }
    read -rp "证书路径 (默认 ${CONFIG_DIR}/cert.crt): " HY2_CERT; HY2_CERT=${HY2_CERT:-$CONFIG_DIR/cert.crt}
    read -rp "私钥路径 (默认 ${CONFIG_DIR}/cert.key): " HY2_KEY; HY2_KEY=${HY2_KEY:-$CONFIG_DIR/cert.key}
    [ -s "$HY2_CERT" ] || { echo -e "${RED}证书不存在: $HY2_CERT${NC}" >&2; exit 1; }
    [ -s "$HY2_KEY" ] || { echo -e "${RED}私钥不存在: $HY2_KEY${NC}" >&2; exit 1; }
    ENABLE_HY2=1
fi

KEYPAIR=$(sing-box generate reality-keypair 2>/dev/null) || {
    echo -e "${RED}无法生成 REALITY 密钥对（需要 sing-box 支持 generate reality-keypair）。${NC}" >&2
    echo -e "${YELLOW}可改用配置链接方式，或手工生成后填入。${NC}" >&2
    exit 1
}
REALITY_PRIVATE_KEY=$(awk '/PrivateKey/ {print $2; exit}' <<< "$KEYPAIR")
REALITY_PUBLIC_KEY=$(awk '/PublicKey/ {print $2; exit}' <<< "$KEYPAIR")
[ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_PUBLIC_KEY" ] || { echo -e "${RED}REALITY 密钥解析失败。${NC}" >&2; exit 1; }
UUID=$(sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
SS_PASSWORD=$(rand_base64 16)
HY2_PASSWORD=$(rand_base64 16)
SHORT_ID=$(rand_hex 8)

TMP_CONFIG=$(mktemp "$CONFIG_DIR/.config.json.XXXXXX")
trap 'rm -f "$TMP_CONFIG"' EXIT

{
cat <<EOF
{
  "dns": {
    "servers": [
      { "tag": "google", "type": "udp", "server": "8.8.8.8" },
      { "tag": "cloudflare", "type": "udp", "server": "1.1.1.1" }
    ],
    "rules": [
      { "query_type": "HTTPS", "action": "reject" },
      { "query_type": ["A", "AAAA"], "server": "cloudflare" }
    ],
    "final": "cloudflare",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "tag": "SS",
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": $SS_PORT,
      "method": "2022-blake3-aes-128-gcm",
      "password": "$SS_PASSWORD",
      "multiplex": { "enabled": true }
    },
    {
      "tag": "VLESS-Vision-Reality",
      "type": "vless",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$REALITY_SNI", "server_port": 443 },
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": [ "$SHORT_ID" ]
        }
      }
    }
EOF
if [ "$ENABLE_HY2" -eq 1 ]; then
cat <<EOF
    ,{
      "tag": "HYSTERIA2",
      "type": "hysteria2",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [ { "password": "$HY2_PASSWORD" } ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$HY2_CERT",
        "key_path": "$HY2_KEY"
      }
    }
EOF
fi
cat <<'EOF'
  ],
  "outbounds": [
    { "tag": "代理出站", "type": "selector", "outbounds": ["直接出站"] },
    { "tag": "直接出站", "type": "direct" }
  ],
  "route": {
    "rules": [
      { "action": "sniff", "sniffer": ["http", "tls", "quic", "dns"] },
      { "type": "logical", "mode": "or", "rules": [ { "port": 53 }, { "protocol": "dns" } ], "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "直接出站" },
      { "rule_set": "geosite-ai", "outbound": "代理出站" }
    ],
    "rule_set": [
      {
        "tag": "geosite-ai",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ai-!cn.srs",
        "download_detour": "直接出站"
      }
    ],
    "final": "直接出站",
    "auto_detect_interface": true,
    "default_domain_resolver": { "server": "cloudflare" }
  },
  "log": { "disabled": false, "level": "info", "timestamp": true }
}
EOF
} > "$TMP_CONFIG"

chmod 0600 "$TMP_CONFIG"
sing-box check -c "$TMP_CONFIG" || { echo -e "${RED}生成的配置未通过 sing-box check，未写入。${NC}" >&2; exit 1; }
if [ -f "$CONFIG_FILE" ]; then
    backup="$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$CONFIG_FILE" "$backup"
    echo -e "${YELLOW}已备份原配置到 $backup${NC}"
fi
install -o root -g root -m 0644 "$TMP_CONFIG" "$CONFIG_FILE"

echo -e "${GREEN}服务端配置已生成: $CONFIG_FILE（所有凭据均为本机随机生成）${NC}"
echo -e "${CYAN}请把以下参数填入客户端：${NC}"
echo "  地址        : <本机公网 IP 或域名>"
echo "  SS          : 端口 $SS_PORT, 方法 2022-blake3-aes-128-gcm, 密码 $SS_PASSWORD"
echo "  VLESS       : 端口 $VLESS_PORT, UUID $UUID, flow xtls-rprx-vision"
echo "  REALITY     : server_name $REALITY_SNI, public_key $REALITY_PUBLIC_KEY, short_id $SHORT_ID"
if [ "$ENABLE_HY2" -eq 1 ]; then
    echo "  hysteria2   : 端口 $HY2_PORT, 密码 $HY2_PASSWORD"
fi
