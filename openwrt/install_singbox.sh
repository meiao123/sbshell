#!/bin/sh
set -eu
command -v opkg >/dev/null 2>&1 || { echo '仅支持 OpenWrt。' >&2; exit 1; }
mkdir -p /var/lock
opkg update
opkg install kmod-nft-tproxy sing-box
# TUN 模式需要 /dev/net/tun（OpenWrt 上通常由 kmod-tun 提供）。部分目标把 tun 编进内核、
# 没有该包，因此这里尽力而为，失败不阻断安装。
opkg install kmod-tun >/dev/null 2>&1 || true
command -v sing-box >/dev/null 2>&1 || { echo 'sing-box 安装失败。' >&2; exit 1; }
[ ! -f /etc/sing-box/config.json ] || sing-box check -c /etc/sing-box/config.json

if [ -e /etc/init.d/sing-box ] && [ ! -f /etc/init.d/sing-box ]; then
    echo 'sing-box init 脚本不是普通文件，拒绝覆盖。' >&2
    exit 1
fi

if [ ! -e /etc/init.d/sing-box ]; then
    cat > /etc/init.d/sing-box <<'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
    [ -s /etc/sing-box/config.json ] || return 1
    /usr/bin/sing-box check -c /etc/sing-box/config.json || return 1
    procd_open_instance
    procd_set_param command /usr/bin/sing-box run -c /etc/sing-box/config.json
    procd_set_param respawn 3600 5 5
    procd_set_param stderr 1
    procd_set_param stdout 1
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger sing-box
}
EOF
    chmod 0755 /etc/init.d/sing-box
else
    echo '检测到已有 /etc/init.d/sing-box，保留包管理器提供的服务脚本。'
fi

/etc/init.d/sing-box enable
/etc/init.d/sing-box restart
