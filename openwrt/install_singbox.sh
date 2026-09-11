#!/bin/sh
set -eu
command -v opkg >/dev/null 2>&1 || { echo '仅支持 OpenWrt。' >&2; exit 1; }
opkg update
opkg install kmod-nft-tproxy sing-box
cat > /etc/init.d/sing-box <<'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
    [ -f /etc/sing-box/config.json ] || return 1
    procd_open_instance
    procd_set_param command /usr/bin/sing-box run -c /etc/sing-box/config.json
    procd_set_param respawn
    procd_set_param stderr 1
    procd_set_param stdout 1
    procd_close_instance
}

stop_service() {
    return 0
}

service_triggers() {
    procd_add_reload_trigger sing-box
}
EOF
chmod 0755 /etc/init.d/sing-box
/etc/init.d/sing-box enable
/etc/init.d/sing-box restart
