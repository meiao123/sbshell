#!/bin/sh
set -eu
# 只认 opkg 会把「没有 opkg」误判成「系统不支持」：OpenWrt 25.12 起改用 apk
# （ImmortalWrt 25.x 同源，实测 apk-tools 3.0.5 上没有 opkg）。按可用者分派，
# 老固件（只有 opkg）的命令序列保持不变。
if command -v opkg >/dev/null 2>&1; then
    PKG_MGR=opkg
elif command -v apk >/dev/null 2>&1; then
    PKG_MGR=apk
else
    echo '仅支持 OpenWrt。未找到 opkg 或 apk 包管理器。' >&2
    exit 1
fi
mkdir -p /var/lock

# run_opkg：把包管理器调用和「已知无害的 opkg 锁清理告警」过滤封装在一起。
# 名字沿用旧名；apk 不会产生该告警，同一套过滤对 apk 也安全。
run_opkg() {
    local log rc
    log=$(mktemp /tmp/sbshell-opkg.XXXXXX) || return 1
    if "$PKG_MGR" "$@" >"$log" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    sed \
        -e '/^Collected errors:$/d' \
        -e "/^ \\* opkg_conf_deinit: Couldn't unlink \/var\/lock\/opkg.lock: No such file or directory$/d" \
        "$log"
    rm -f "$log"
    return "$rc"
}

# 安装子命令两代不同：opkg install / apk add（apk 没有 install 子命令）。
pkg_install() {
    if [ "$PKG_MGR" = apk ]; then run_opkg add "$@"; else run_opkg install "$@"; fi
}

run_opkg update
pkg_install kmod-nft-tproxy sing-box
# TUN 模式需要 /dev/net/tun（OpenWrt 上通常由 kmod-tun 提供）。部分目标把 tun 编进内核、
# 没有该包，因此这里尽力而为，失败不阻断安装。
pkg_install kmod-tun >/dev/null 2>&1 || true
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
