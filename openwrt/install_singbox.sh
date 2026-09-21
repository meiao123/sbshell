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

# ---------- 上游最新稳定版（按当前 CPU 架构取官方 OpenWrt .apk） ----------
# 发行版 feed 的 sing-box 会落后上游（真机：feed 1.12.25 vs 上游 1.14.1）。上游为每个
# OpenWrt 架构都发布了官方 apk，资产名与 `apk --print-arch` 输出一一对应（无需映射表）。
# 本段只负责「尝试装上游最新」；失败一律回退到下面的发行版包安装，不影响可用性。
SINGBOX_SOURCE=${SBSHELL_SINGBOX_SOURCE:-latest}   # latest | feed
SINGBOX_RELEASE_API=https://api.github.com/repos/SagerNet/sing-box/releases/latest

# 已安装版本的基础版本号（去掉 OpenWrt 的 -rN 修订后缀；未安装则输出空）
installed_base_version() {
    local raw
    raw=$(sing-box version 2>/dev/null | sed -n 's/^sing-box version \([^ ]*\).*/\1/p' | head -n1 || true)
    printf '%s\n' "${raw%%-r*}"
}

# 从 release JSON 里挑出目标架构的资产，输出三行：下载地址 / digest / 字节大小。
# 注意 JSON 里字段顺序是 name -> digest -> browser_download_url，因此要按序累积判断。
pick_asset() {
    local json="$1" arch="$2"
    awk -v arch="$arch" '
        /"name":/ { n=$0; sub(/.*"name": *"/,"",n); sub(/".*/,"",n)
                    matched = (index(n, "openwrt_" arch ".apk") > 0) }
        /"digest":/ { if (matched) { d=$0; sub(/.*"digest": *"/,"",d); sub(/".*/,"",d) } }
        /"size":/   { if (matched) { s=$0; sub(/.*"size": */,"",s); sub(/[^0-9].*/,"",s) } }
        /"browser_download_url":/ { if (matched) {
                    u=$0; sub(/.*"browser_download_url": *"/,"",u); sub(/".*/,"",u)
                    print u; print d; print s; exit } }
    ' "$json"
}

# 回滚：把发行版 feed 里那份 sing-box 装回去（事前用 apk fetch 存到工作目录）。
rollback_to_feed() {
    local feed
    feed=$(ls "$workdir"/sing-box-*.apk 2>/dev/null | head -n1 || true)
    [ -n "$feed" ] || return 1
    run_opkg del sing-box >/dev/null 2>&1 || true
    run_opkg add --allow-untrusted "$feed" >/dev/null 2>&1 || return 1
    return 0
}

# 返回 0 表示「上游最新版已就位，不用再装 feed 包」；返回 1 表示让调用方回退 feed。
install_latest_singbox() {
    local arch json tag url digest size_kb free_kb actual apkfile
    [ "$SINGBOX_SOURCE" = latest ] || return 1
    [ "$PKG_MGR" = apk ] || return 1   # opkg 固件：上游没有 .ipk，保持原样
    arch=$(apk --print-arch 2>/dev/null || cat /etc/apk/arch 2>/dev/null || true)
    [ -n "$arch" ] || { echo '无法确定当前 CPU 架构，改用发行版软件包。' >&2; return 1; }
    # 30 MB 级下载不能放 /tmp（tmpfs 即内存），放 sing-box 目录（overlay）并检查空间。
    workdir=$(mktemp -d /etc/sing-box/.pkg.XXXXXX 2>/dev/null || true)
    [ -n "$workdir" ] || { echo '无法创建包临时目录，改用发行版软件包。' >&2; return 1; }
    trap 'rm -rf "$workdir"' EXIT INT TERM
    json="$workdir/release.json"
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 120 "$SINGBOX_RELEASE_API" -o "$json"; then
        echo '查询上游最新版本失败（网络或 API 配额），改用发行版软件包。' >&2; return 1
    fi
    tag=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$json" | head -n1 || true)
    [ -n "$tag" ] || { echo '上游版本信息不可解析，改用发行版软件包。' >&2; return 1; }
    url=$(pick_asset "$json" "$arch" | sed -n '1p')
    digest=$(pick_asset "$json" "$arch" | sed -n '2p')
    size=$(pick_asset "$json" "$arch" | sed -n '3p')
    [ -n "$url" ] || { echo "上游没有适配 $arch 的 OpenWrt 包，改用发行版软件包。" >&2; return 1; }
    if [ "$(installed_base_version)" = "${tag#v}" ]; then
        echo "sing-box 已是上游最新稳定版 ${tag#v}（$arch）。"
        return 0
    fi
    if [ -n "$size" ]; then
        free_kb=$(df -k "$workdir" 2>/dev/null | awk 'NR==2 {print $4}')
        size_kb=$((size / 1024))
        if [ -n "$free_kb" ] && [ "$free_kb" -lt $((size_kb + size_kb / 3)) ]; then
            echo "可用空间不足（需要约 $((size_kb / 1024)) MiB），改用发行版软件包。" >&2; return 1
        fi
    fi
    apkfile="$workdir/${url##*/}"
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 300 "$url" -o "$apkfile"; then
        echo '下载上游 sing-box 包失败，改用发行版软件包。' >&2; return 1
    fi
    if [ -n "$digest" ]; then
        if command -v sha256sum >/dev/null 2>&1; then
            actual=$(sha256sum "$apkfile" | awk '{print $1}')
            if [ "$actual" != "${digest#sha256:}" ]; then
                echo '上游包 sha256 校验失败，已中止（改用发行版软件包）。' >&2; return 1
            fi
            echo "已校验上游包 sha256（${tag#v} / $arch）。"
        else
            echo '提示：本机没有 sha256sum，跳过完整性校验（下载走 HTTPS）。' >&2
        fi
    else
        echo '提示：上游未在 API 中提供 sha256，跳过完整性校验（下载走 HTTPS）。' >&2
    fi
    # 先取一份发行版包，出问题能装回去。
    apk fetch -o "$workdir" sing-box >/dev/null 2>&1 || true
    if ! run_opkg add --allow-untrusted "$apkfile"; then
        echo '安装上游 sing-box 包失败。' >&2
        rollback_to_feed && echo '已回滚到发行版软件包。' >&2
        return 1
    fi
    if [ "$(installed_base_version)" != "${tag#v}" ]; then
        echo "安装后版本核对失败（期望 ${tag#v}，实际 $(installed_base_version)），正在回滚。" >&2
        rollback_to_feed && echo '已回滚到发行版软件包。' >&2
        return 1
    fi
    echo "sing-box 已更新到上游最新稳定版 ${tag#v}（$arch，来自官方 OpenWrt 包）。"
    return 0
}

run_opkg update
pkg_install kmod-nft-tproxy
# sing-box 优先装上游最新稳定版（apk 固件 + 架构匹配）；任何失败都回退发行版软件包，
# 保证「拿不到最新版」不会变成「装不上」。
if install_latest_singbox; then
    :
else
    pkg_install sing-box
fi
# TUN 模式需要 /dev/net/tun（OpenWrt 上通常由 kmod-tun 提供）。部分目标把 tun 编进内核、
# 没有该包，因此这里尽力而为，失败不阻断安装。
pkg_install kmod-tun >/dev/null 2>&1 || true
command -v sing-box >/dev/null 2>&1 || { echo 'sing-box 安装失败。' >&2; exit 1; }

# 预检只为「不拿坏配置去启动服务」。现有配置与当前 sing-box 版本不兼容时（例如 1.11 起废弃的
# block/dns 特殊出站）不能让整个初始化失败：初始化失败会让 sb 每次都重跑引导、连菜单都进不去，
# 用户能看到的只剩 sing-box 自己那句 FATAL。这里改为提示 + 跳过启动，安装步骤本身照旧成功。
# 另外新版 sing-box 会把废弃项打成一整串 WARN/ERROR/FATAL（固件升级残留的旧配置必然触发），
# 整段倒给用户只会让人以为安装失败，所以先收集输出、只透出其中一行真正的原因。
SKIP_RESTART=0
check_log=$(mktemp /tmp/sbshell-check.XXXXXX 2>/dev/null || echo "/tmp/sbshell-check.log")
if [ -f /etc/sing-box/config.json ] && ! sing-box check -c /etc/sing-box/config.json 2>"$check_log"; then
    SKIP_RESTART=1
    echo '现有 /etc/sing-box/config.json 未通过校验，已跳过启动 sing-box。' >&2
    reason=$(grep -m1 'FATAL' "$check_log" 2>/dev/null || grep -m1 'ERROR' "$check_log" 2>/dev/null || tail -n1 "$check_log" 2>/dev/null || true)
    if [ -n "$reason" ]; then
        printf '  原因: %s\n' "$reason" >&2
    fi
    echo '可在菜单中选择 2 手动更新配置重新下载；若配置含已废弃的 block/dns 出站，请迁移为新的规则动作，或临时设置 ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true。' >&2
fi
rm -f "$check_log"

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
    # 包管理器提供的脚本（net/sing-box/files/sing-box.init）按 UCI 开关启动：
    #   config_get_bool enabled main enabled 0
    #   [ "$enabled" -eq 1 ] || return 0
    # 而包自带的 /etc/config/sing-box 默认 option enabled '0'，于是 start/restart
    # 返回 0 却什么都不做——sing-box 装完也不会运行（真机表现为「sing-box 未运行，请检查日志。」
    # 与「新配置启动失败，已恢复旧配置。」）。这里显式打开开关。
    if command -v uci >/dev/null 2>&1; then
        uci -q get sing-box.main >/dev/null 2>&1 || uci -q set sing-box.main=sing-box || true
        uci -q set sing-box.main.enabled=1 || true
        # conffile 为空时包脚本会执行 `sing-box run -c ''`，同样起不来。
        [ -n "$(uci -q get sing-box.main.conffile 2>/dev/null || true)" ] || uci -q set sing-box.main.conffile=/etc/sing-box/config.json || true
        uci -q commit sing-box || true
    fi
fi

/etc/init.d/sing-box enable
if [ "$SKIP_RESTART" != 1 ]; then
    # rc.common/procd 在没有已注册实例时会回显 ubus 噪音（短形态 `Command failed: Not found`
    # 与带命令名的长形态）；本脚本是 #!/bin/sh，busybox 的 ash 没有进程替换，故用可移植的
    # mktemp + sed 过滤，并保留 restart 的真实退出码（失败即失败，行为不变）。
    restart_err=$(mktemp /tmp/sbshell-restart.XXXXXX 2>/dev/null || echo "/tmp/sbshell-restart.$$")
    if /etc/init.d/sing-box restart 2>"$restart_err"; then rc=0; else rc=$?; fi
    sed '/^Command failed:.*Not found/d' "$restart_err" >&2
    rm -f "$restart_err"
    [ "$rc" -eq 0 ] || exit "$rc"
fi
