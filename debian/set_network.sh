#!/bin/bash
set -Eeuo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
trap 'echo -e "\n${RED}操作已取消。${NC}"; exit 1' SIGINT

require_service() {
    systemctl list-unit-files --type=service --no-legend "$1.service" 2>/dev/null | grep -q .
}
service_active() {
    systemctl is-active --quiet "$1.service"
}

if service_active NetworkManager || service_active systemd-networkd || service_active systemd-resolved; then
    echo -e "${RED}检测到 NetworkManager/systemd-networkd/systemd-resolved 正在管理网络。${NC}" >&2
    echo -e "${YELLOW}为避免覆盖其配置，本脚本仅支持由 ifupdown/networking.service 管理的网络。${NC}" >&2
    exit 1
fi
require_service networking || { echo -e "${RED}未找到 networking.service，无法安全修改 ifupdown 配置。${NC}" >&2; exit 1; }

[ -f /etc/network/interfaces ] || { echo -e "${RED}缺少 /etc/network/interfaces。${NC}" >&2; exit 1; }
[ ! -L /etc/resolv.conf ] || { echo -e "${RED}/etc/resolv.conf 是符号链接，疑似由其他解析服务管理；已拒绝覆盖。${NC}" >&2; exit 1; }

CURRENT_IP=$(ip -4 addr show scope global | awk '/inet / {print $2; exit}' || true)
CURRENT_GATEWAY=$(ip -4 route show default | awk 'NR==1 {print $3}' || true)
CURRENT_DNS=$(awk '/^nameserver / {print $2}' /etc/resolv.conf | tr '\n' ' ' || true)
printf '%b\n' "${YELLOW}当前 IP 地址: ${CURRENT_IP:-未知}${NC}"
printf '%b\n' "${YELLOW}当前网关地址: ${CURRENT_GATEWAY:-未知}${NC}"
printf '%b\n' "${YELLOW}当前 DNS 服务器: ${CURRENT_DNS:-未知}${NC}"

INTERFACE=$(ip -4 route show default | awk 'NR==1 {print $5; exit}')
[ -n "$INTERFACE" ] || { echo -e "${RED}未找到默认路由接口。${NC}"; exit 1; }
echo -e "${YELLOW}检测到的网络接口: $INTERFACE${NC}"

if awk -v iface="$INTERFACE" '$1 == "iface" && $2 != "lo" && $2 != iface {found=1} END {exit found}' /etc/network/interfaces; then
    :
else
    echo -e "${RED}/etc/network/interfaces 包含其他非 lo 接口配置，本脚本拒绝覆盖。${NC}" >&2
    exit 1
fi
if grep -Eq '^[[:space:]]*(source|source-directory)[[:space:]]' /etc/network/interfaces; then
    echo -e "${RED}/etc/network/interfaces 包含 source/source-directory，本脚本拒绝覆盖以避免丢失分片配置。${NC}" >&2
    exit 1
fi

valid_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && awk -F. '{for(i=1;i<=4;i++) if($i>255) exit 1}' <<< "$1"; }
valid_dns() { valid_ipv4 "$1" || [[ "$1" =~ ^([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}$ ]]; }

while true; do
    read -rp "请输入静态 IP 地址（支持 CIDR，例如 192.168.1.10/24）: " IP_ADDRESS
    read -rp "请输入网关地址: " GATEWAY
    read -rp "请输入 DNS 服务器地址 (多个地址用空格分隔): " DNS_SERVERS

    if ! [[ "$IP_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo -e "${RED}IPv4 必须使用 CIDR 格式，例如 192.168.1.10/24。${NC}"; continue
    fi
    IP_ONLY=${IP_ADDRESS%/*}; PREFIX=${IP_ADDRESS#*/}
    valid_ipv4 "$IP_ONLY" || { echo -e "${RED}IP 地址无效。${NC}"; continue; }
    [ "$PREFIX" -le 32 ] || { echo -e "${RED}CIDR 前缀无效。${NC}"; continue; }
    valid_ipv4 "$GATEWAY" || { echo -e "${RED}IPv4 网关地址无效。${NC}"; continue; }

    dns_ok=true
    for dns in $DNS_SERVERS; do valid_dns "$dns" || dns_ok=false; done
    $dns_ok || { echo -e "${RED}DNS 地址中存在无效值。${NC}"; continue; }

    echo -e "${YELLOW}IP: $IP_ADDRESS${NC}"
    echo -e "${YELLOW}网关: $GATEWAY${NC}"
    echo -e "${YELLOW}DNS: $DNS_SERVERS${NC}"
    read -rp "是否确认上述配置？(y/n): " confirm_choice
    [[ "$confirm_choice" =~ ^[Yy]$ ]] || continue

    INTERFACES_FILE=/etc/network/interfaces
    RESOLV_CONF_FILE=/etc/resolv.conf
    backup_dir=$(mktemp -d /tmp/sbshell-network-backup.XXXXXX)
    cp -a "$INTERFACES_FILE" "$backup_dir/interfaces"
    cp -a "$RESOLV_CONF_FILE" "$backup_dir/resolv.conf"

    tmp_interfaces=$(mktemp /etc/network/.interfaces.XXXXXX)
    tmp_resolv=$(mktemp /etc/.resolv.conf.XXXXXX)
    cleanup_tmp() { rm -f "$tmp_interfaces" "$tmp_resolv"; }
    trap cleanup_tmp RETURN
    cat > "$tmp_interfaces" <<EOL
# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
allow-hotplug $INTERFACE
iface $INTERFACE inet static
    address $IP_ADDRESS
    gateway $GATEWAY
EOL
    for dns in $DNS_SERVERS; do printf 'nameserver %s\n' "$dns" >> "$tmp_resolv"; done
    chown root:root "$tmp_interfaces" "$tmp_resolv"
    chmod 0644 "$tmp_interfaces" "$tmp_resolv"
    mv -f "$tmp_interfaces" "$INTERFACES_FILE"
    mv -f "$tmp_resolv" "$RESOLV_CONF_FILE"

    if systemctl restart networking; then
        sleep 2
        if ip -4 addr show dev "$INTERFACE" | grep -q "inet $IP_ADDRESS" && ip -4 route show default | grep -q "via $GATEWAY dev $INTERFACE"; then
            rm -rf "$backup_dir"
            echo -e "${GREEN}网络配置完成。${NC}"
            break
        fi
    fi

    echo -e "${RED}网络配置未通过重启/连通性验证，正在恢复原配置。${NC}" >&2
    cp -a "$backup_dir/interfaces" "$INTERFACES_FILE"
    cp -a "$backup_dir/resolv.conf" "$RESOLV_CONF_FILE"
    systemctl restart networking || true
    rm -rf "$backup_dir"
    exit 1
done
