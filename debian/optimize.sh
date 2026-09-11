#!/bin/bash
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

# Conservative network tuning. Existing sysctl is backed up and only supported keys are changed.
BACKUP_DIR=/etc/sing-box/backup/optimize
mkdir -p "$BACKUP_DIR"
cp -a /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
cp -a /etc/security/limits.conf "$BACKUP_DIR/limits.conf.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

cat > /etc/sysctl.d/99-sbshell-network.conf <<'EOF'
vm.swappiness = 5
fs.file-max = 1048576
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 65536
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.optmem_max = 8388608
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 16384 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system || echo "警告: 部分 sysctl 参数应用失败（内核不支持时属正常）。" >&2

# Prefer BBR/fq only when supported; never fail the whole optimization on unsupported kernels.
modprobe tcp_bbr 2>/dev/null || true
if grep -qw bbr /proc/sys/net/ipv4/tcp_allowed_congestion_control 2>/dev/null; then
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
fi
# 不要用 /proc/sys/net/core/default_qdisc 判断 fq 是否可用：该文件是“当前”队列算法的值，
# 值为 fq_codel 时 `grep -w fq` 永远匹配不到；/sys/module/sch_fq 对内建模块也不一定存在。
# 直接尝试写入并检查返回值。
if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
    echo "已启用 fq 队列算法（对新创建的网卡生效）。"
else
    echo "提示: 内核不支持 fq 队列算法，已跳过。" >&2
fi

echo "网络参数优化完成。原始配置已备份到 $BACKUP_DIR。"
