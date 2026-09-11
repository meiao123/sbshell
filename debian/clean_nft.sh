#!/bin/bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

systemctl stop sing-box
if command -v nft >/dev/null 2>&1; then
    nft list table inet sing-box >/dev/null 2>&1 && nft delete table inet sing-box || true
fi

# 仅清理 sbshell 自有规则，不触碰系统其他 nftables 规则。
echo "sing-box 服务已停止，sing-box 相关防火墙规则已清理。"
