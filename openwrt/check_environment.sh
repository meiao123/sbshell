#!/bin/bash

if [ "$(id -u)" != "0" ]; then
    echo "错误: 此脚本需要 root 权限"
    exit 1
fi

if command -v sing-box &> /dev/null; then
    # A-24：不要用 awk '{print $3}' 依赖第三方输出的字段位置 —— 版本行格式一变
    # （或带附加信息/本地化）就会静默得到空版本号。按前缀取第一个字段，取不到就说清楚。
    current_version=$(sing-box version 2>/dev/null | sed -n 's/^sing-box version \([^ ]*\).*/\1/p' | head -n1)
    if [ -n "$current_version" ]; then
        echo "sing-box 已安装，版本：$current_version"
    else
        echo "sing-box 已安装，但无法从版本输出解析出版本号（输出格式可能已变化）："
        sing-box version 2>&1 | head -n1
    fi
else
    echo "sing-box 未安装"
fi

# A-24：把「缺 nft / 缺 TUN」这类环境问题在入口就暴露出来，而不是等 configure_* 才报错。
if command -v nft >/dev/null 2>&1; then
    nft_version=$(nft --version 2>/dev/null | head -n1)
    echo "nft 可用${nft_version:+：$nft_version}"
else
    echo "警告：未找到 nft，TProxy/TUN 规则无法下发（请安装 nftables）。"
fi
if [ -c /dev/net/tun ]; then
    echo "/dev/net/tun 可用，TUN 模式可启用。"
else
    echo "警告：/dev/net/tun 不存在，TUN 模式不可用（请确认内核模块 tun 已加载）。"
fi