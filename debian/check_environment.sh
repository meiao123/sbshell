#!/bin/bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "错误: 此脚本需要 root 权限" >&2; exit 1; }
command -v sysctl >/dev/null 2>&1 || { echo "错误: 缺少 sysctl" >&2; exit 1; }

if command -v sing-box >/dev/null 2>&1; then
    current_version=$(sing-box version 2>/dev/null | awk '/sing-box version/ {print $3; exit}')
    echo "sing-box 已安装，版本：${current_version:-未知}"
else
    echo "sing-box 未安装"
fi

ipv4_forward=$(sysctl -n net.ipv4.ip_forward)
ipv6_forward=$(sysctl -n net.ipv6.conf.all.forwarding)

if [ "$ipv4_forward" -eq 1 ] && [ "$ipv6_forward" -eq 1 ]; then
    echo "IP 转发已开启"
    exit 0
fi

echo "开启 IP 转发..."
install -d -o root -g root -m 0755 /etc/sysctl.d
cat > /etc/sysctl.d/99-sbshell-forwarding.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
chmod 0644 /etc/sysctl.d/99-sbshell-forwarding.conf
sysctl --system >/dev/null
[ "$(sysctl -n net.ipv4.ip_forward)" -eq 1 ] && [ "$(sysctl -n net.ipv6.conf.all.forwarding)" -eq 1 ] || {
    echo "错误: IP 转发启用失败。" >&2
    exit 1
}
echo "IP 转发已成功开启"
