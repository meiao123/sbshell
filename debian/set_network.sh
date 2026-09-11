#!/bin/bash
set -Eeuo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
trap 'echo -e "\n${RED}操作已取消。${NC}"; exit 1' SIGINT

CURRENT_IP=$(ip -4 addr show scope global | awk '/inet / {print $2}' | head -n 1 || true)
CURRENT_GATEWAY=$(ip -4 route show default | awk 'NR==1 {print $3}' || true)
CURRENT_DNS=$(awk '/^nameserver / {print $2}' /etc/resolv.conf | tr '\n' ' ' || true)
printf '%b\n' "${YELLOW}当前 IP 地址: ${CURRENT_IP:-未知}${NC}"
printf '%b\n' "${YELLOW}当前网关地址: ${CURRENT_GATEWAY:-未知}${NC}"
printf '%b\n' "${YELLOW}当前 DNS 服务器: ${CURRENT_DNS:-未知}${NC}"

INTERFACE=$(ip -br link show up | awk '$1 != "lo" {print $1; exit}')
[ -n "$INTERFACE" ] || { echo -e "${RED}未找到活动网络接口。${NC}"; exit 1; }
echo -e "${YELLOW}检测到的网络接口: $INTERFACE${NC}"

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
    backup_dir=$(mktemp -d)
    cp -a "$INTERFACES_FILE" "$backup_dir/interfaces" 2>/dev/null || true
    cp -a "$RESOLV_CONF_FILE" "$backup_dir/resolv.conf" 2>/dev/null || true

    tmp_interfaces=$(mktemp)
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
    install -o root -g root -m 0644 "$tmp_interfaces" "$INTERFACES_FILE"
    rm -f "$tmp_interfaces"

    tmp_resolv=$(mktemp)
    for dns in $DNS_SERVERS; do printf 'nameserver %s\n' "$dns" >> "$tmp_resolv"; done
    install -o root -g root -m 0644 "$tmp_resolv" "$RESOLV_CONF_FILE"
    rm -f "$tmp_resolv"

    if systemctl restart networking; then
        rm -rf "$backup_dir"
        echo -e "${GREEN}网络配置完成。${NC}"
        break
    fi

    echo -e "${RED}网络服务重启失败，正在恢复原配置。${NC}" >&2
    [ -f "$backup_dir/interfaces" ] && install -o root -g root -m 0644 "$backup_dir/interfaces" "$INTERFACES_FILE"
    [ -f "$backup_dir/resolv.conf" ] && install -o root -g root -m 0644 "$backup_dir/resolv.conf" "$RESOLV_CONF_FILE"
    systemctl restart networking || true
    rm -rf "$backup_dir"
    exit 1
done
