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

# 读取 sysctl 时不要把「键不存在」当成致命错误：内核未编译 IPv6 时
# net.ipv6.conf.all.forwarding 不存在，旧代码会让 set -e 静默中止整个初始化，
# 空值参与 [ -eq ] 也会打印 "integer expression expected"。
sysctl_value() { sysctl -n "$1" 2>/dev/null | tr -d '[:space:]' || true; }

ipv4_forward=$(sysctl_value net.ipv4.ip_forward)
ipv6_forward=$(sysctl_value net.ipv6.conf.all.forwarding)
[ -n "$ipv4_forward" ] || { echo "错误: 无法读取 net.ipv4.ip_forward。" >&2; exit 1; }

if [ "$ipv4_forward" = 1 ] && [ "${ipv6_forward:-0}" = 1 ]; then
    echo "IP 转发已开启（IPv4/IPv6）"
    exit 0
fi

echo "开启 IP 转发..."
install -d -o root -g root -m 0755 /etc/sysctl.d
cat > /etc/sysctl.d/99-sbshell-forwarding.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
chmod 0644 /etc/sysctl.d/99-sbshell-forwarding.conf
sysctl --system >/dev/null || true

ipv4_forward=$(sysctl_value net.ipv4.ip_forward)
ipv6_forward=$(sysctl_value net.ipv6.conf.all.forwarding)
if [ "$ipv4_forward" != 1 ]; then
    echo "错误: IPv4 转发启用失败。" >&2
    exit 1
fi
[ "${ipv6_forward:-0}" = 1 ] || echo "提示: 本机未启用 IPv6 转发（内核不支持 IPv6 时可忽略）。"
echo "IP 转发已成功开启"
