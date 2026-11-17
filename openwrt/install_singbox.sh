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
# 发行版 feed 的 sing-box 会落后上游（真机：feed 1.12.25 vs 上游 1.14.x）。上游为每个
# OpenWrt 架构都发布了官方包（apk 与 ipk 都有），资产名见下面的 singbox_asset_url()。
# 本段只负责「尝试装上游最新」；失败一律回退到下面的发行版包安装，不影响可用性。
SINGBOX_SOURCE=${SBSHELL_SINGBOX_SOURCE:-latest}   # latest | feed
# 版本解析优先走 github.com 的 302（releases/latest → /releases/tag/vX.Y.Z），
# 不消耗 api.github.com 的「60 次/小时/IP」配额；API 只用来取 digest/size（可选）。
SINGBOX_RELEASE_API=https://api.github.com/repos/SagerNet/sing-box/releases/latest
SINGBOX_RELEASES_LATEST=https://github.com/SagerNet/sing-box/releases/latest
# 固定版本（1.14.4 或 v1.14.4）：跳过全部版本解析，直接按版本拼地址，便于可复现部署。
SBSHELL_SINGBOX_VERSION=${SBSHELL_SINGBOX_VERSION:-}

# 架构名必须与上游资产名一致，所以优先用 /etc/os-release 里的 OPENWRT_ARCH（上游安装脚本同款），
# 拿不到时再退回 apk 自己的输出。
detect_openwrt_arch() {
    local a=''
    if [ -r /etc/os-release ]; then
        # `|| true`：. 是 POSIX 特殊内建，加载失败在部分 shell 里会带崩 subshell
        # （真机 busybox ash 实测 rc=2 直接退出整份脚本）；[ -r ] 已挡住「文件不存在」。
        a=$(. /etc/os-release 2>/dev/null || true; printf '%s' "${OPENWRT_ARCH:-}")
    fi
    [ -n "$a" ] || a=$(apk --print-arch 2>/dev/null || true)
    [ -n "$a" ] || a=$(cat /etc/apk/arch 2>/dev/null || true)
    printf '%s\n' "$a"
}

# 固定版本的规范化：接受 1.14.4 / v1.14.4 / 1.14.4-beta.2；非法值返回空（走自动解析）。
normalize_singbox_pin() {
    local v=${SBSHELL_SINGBOX_VERSION#v}
    case "$v" in
        [0-9]*[0-9]) ;;
        *) printf '\n'; return 0 ;;
    esac
    case "$v" in
        *[!0-9A-Za-z.-]*) printf '\n'; return 0 ;;
    esac
    printf 'v%s\n' "$v"
}

# 不消耗 API 配额地解析最新版本：跟随 releases/latest 的 302，从最终 URL 里取 tag。
resolve_latest_tag_by_redirect() {
    local effective='' tail=''
    effective=$(curl --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 8 --max-time 20 -o /dev/null -w '%{url_effective}' \
        "$SINGBOX_RELEASES_LATEST" 2>/dev/null || true)
    case "$effective" in
        */releases/tag/v[0-9]*) tail=${effective##*/releases/tag/} ;;
        *) printf '\n'; return 0 ;;
    esac
    # 去掉可能跟在 tag 后面的 ?query / #fragment / 尾斜杠，再确认形状是 v<数字>…
    tail=${tail%%[?#]*}
    tail=${tail%%/*}
    case "$tail" in
        v[0-9]*) printf '%s\n' "$tail" ;;
        *) printf '\n' ;;
    esac
}

# GitHub token 只从环境变量读，不写进任何配置文件。
# 只接受 token 的常见字符集：值来自环境变量，若含 `"` 会把 curl 配置文件注入成额外参数。
github_api_token() {
    local t=${SBSHELL_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}
    case "$t" in
        ''|*[!0-9A-Za-z_.-]*) printf '\n' ;;
        *) printf '%s\n' "$t" ;;
    esac
}

# 取 release JSON（digest/size 的来源）。带 token 时配额是 5000 次/小时；token 写进 0600 的
# 临时 curl 配置文件、不放命令行参数，避免出现在 ps 的 argv 里。
fetch_release_json() {
    local out="$1" tok cfg rc=0
    tok=$(github_api_token)
    if [ -z "$tok" ]; then
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 60 \
            -H 'Accept: application/vnd.github+json' \
            "$SINGBOX_RELEASE_API" -o "$out" 2>/dev/null
        return $?
    fi
    cfg=$(mktemp /tmp/sbshell-api.XXXXXX) || return 1
    printf 'header = "Authorization: Bearer %s"\n' "$tok" > "$cfg" || rc=1
    if [ "$rc" -eq 0 ]; then
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 60 --config "$cfg" \
            -H 'Accept: application/vnd.github+json' \
            "$SINGBOX_RELEASE_API" -o "$out" 2>/dev/null || rc=$?
    fi
    rm -f "$cfg"
    return "$rc"
}


# 下载上游 .apk：静默 curl 下最多 300 秒零输出，慢速/被限速时看起来就是「卡死」。
# 这里放到后台，前台每 2 秒打印已下载大小；并用 --speed-limit/--speed-time 让
# 「完全没有速度」的连接快速失败、回退到发行版包，而不是干等满 5 分钟。
download_upstream_asset() { # $1=url $2=目标文件 $3=期望字节数（可空）
    local url="$1" dst="$2" want="${3:-}" err pid rc got
    err=$(mktemp /tmp/sbshell-apk-err.XXXXXX 2>/dev/null || echo "/tmp/sbshell-apk-err.$$")
    rm -f "$dst"
    : > "$dst"   # 先建空文件：轮询里 wc 读它时不会因「文件不存在」往 stderr 刷错误
    if [ -n "$want" ]; then
        printf '正在下载上游 sing-box 包（约 %s MiB，最多 300 秒）…\n' "$((want / 1048576))"
    else
        printf '正在下载上游 sing-box 包（最多 300 秒）…\n'
    fi
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 300 --speed-limit 10240 --speed-time 30 \
        "$url" -o "$dst" 2>"$err" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        got=$(wc -c < "$dst" 2>/dev/null || echo 0)
        case "$want" in
            ''|*[!0-9]*) printf '\r  已下载 %s KiB' "$((got / 1024))" ;;
            *) if [ "$want" -gt 0 ]; then
                   printf '\r  已下载 %s KiB / %s KiB' "$((got / 1024))" "$((want / 1024))"
               else
                   printf '\r  已下载 %s KiB' "$((got / 1024))"
               fi ;;
        esac
        sleep 2
    done
    wait "$pid"; rc=$?
    printf '\n'
    if [ "$rc" -ne 0 ]; then
        echo '下载失败或超时。' >&2
        if [ -s "$err" ]; then
            head -n 2 "$err" | sed 's/^/  /' >&2
        fi
        rm -f "$dst" "$err"
        return 1
    fi
    got=$(wc -c < "$dst" 2>/dev/null || echo 0)
    printf '下载完成：%s KiB\n' "$((got / 1024))"
    rm -f "$err"
    return 0
}
# 上游官方 OpenWrt 包地址（资产名由上游发布流程固定：sing-box_<版本>_openwrt_<架构>.apk）。
singbox_asset_url() {
    printf 'https://github.com/SagerNet/sing-box/releases/download/%s/sing-box_%s_openwrt_%s.apk\n' \
        "$1" "${1#v}" "$2"
}

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
    # set -eu 下 `local x` 只是「声明」，读取 $x 会报 unbound：这里全部显式初始化。
    local arch='' json='' tag='' pin='' api_tag='' url='' digest='' size='' size_kb='' free_kb='' actual='' apkfile=''
    [ "$SINGBOX_SOURCE" = latest ] || return 1
    [ "$PKG_MGR" = apk ] || return 1   # opkg 固件：上游 .ipk 已发布但未在真机验证，保持发行版包
    arch=$(detect_openwrt_arch)
    [ -n "$arch" ] || { echo '无法确定当前 CPU 架构，改用发行版软件包。' >&2; return 1; }
    # 30 MB 级下载不能放 /tmp（tmpfs 即内存），放 sing-box 目录（overlay）并检查空间。
    workdir=$(mktemp -d /etc/sing-box/.pkg.XXXXXX 2>/dev/null || true)
    [ -n "$workdir" ] || { echo '无法创建包临时目录，改用发行版软件包。' >&2; return 1; }
    # EXIT 只清理；INT/TERM 必须带 exit，否则 Ctrl+C 被吞掉后安装会继续往下跑。
    trap 'rm -rf "$workdir"' EXIT
    trap 'rm -rf "$workdir"; exit 130' INT TERM
    json="$workdir/release.json"

    # 版本解析顺序：显式固定版本 → github.com 重定向（不耗 API 配额）→ API latest。
    pin=$(normalize_singbox_pin)
    if [ -n "$pin" ]; then
        tag="$pin"
        echo "按 SBSHELL_SINGBOX_VERSION 安装固定版本 ${tag#v}（$arch）。"
    else
        tag=$(resolve_latest_tag_by_redirect)
        if [ -n "$tag" ]; then
            echo "已从 GitHub 发布页解析上游最新版本 ${tag#v}（未消耗 API 配额）。"
        fi
        # digest/size 只能从 API 拿：尽力而为，限流/超时只跳过校验，不影响安装。
        # 固定版本时不查 API：url 按版本拼、digest 也用不上，少一个失败点，也便于离线复现。
        echo '查询发布页资产信息（最多 60 秒；失败则跳过 sha256 校验）…'
        if fetch_release_json "$json"; then
            api_tag=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$json" | head -n1 || true)
            [ -n "$tag" ] || tag="$api_tag"
            # 只有 API 的 tag 与解析结果一致时才采信 url/digest/size：
            # 否则可能拿 A 版本的哈希去校验 B 版本的包（必然失败并白白回滚）。
            if [ -n "$api_tag" ] && [ "$api_tag" = "$tag" ]; then
                url=$(pick_asset "$json" "$arch" | sed -n '1p')
                digest=$(pick_asset "$json" "$arch" | sed -n '2p')
                size=$(pick_asset "$json" "$arch" | sed -n '3p')
            fi
        else
            rm -f "$json"
            echo '提示：拿不到 GitHub API 的版本信息（多为未认证限流），跳过 sha256 校验继续安装。' >&2
        fi
    fi
    [ -n "$tag" ] || { echo '无法确定上游 sing-box 版本（网络或 API 配额），改用发行版软件包。' >&2; return 1; }
    [ -n "$url" ] || url=$(singbox_asset_url "$tag" "$arch")
    if [ "$(installed_base_version)" = "${tag#v}" ]; then
        if [ -n "$pin" ]; then
            echo "sing-box 已是固定版本 ${tag#v}（$arch）。"
        else
            echo "sing-box 已是上游最新稳定版 ${tag#v}（$arch）。"
        fi
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
    if ! download_upstream_asset "$url" "$apkfile" "${size:-}"; then
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
    echo '正在预取发行版包（回滚用，失败可忽略）…'
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

# 尽力而为：离线/索引损坏时 update 失败不应把整轮初始化带走（否则连菜单都进不去）。
run_opkg update || echo '提示：包索引刷新失败，继续尝试用本地缓存安装。' >&2
# 纯 TUN 用户不该被 TProxy 依赖挡住：失败只提示，不中断。
pkg_install kmod-nft-tproxy || echo '提示：kmod-nft-tproxy 安装失败，TProxy 模式可能不可用（TUN 不受影响）。' >&2
# TUN auto_redirect 在 Linux 上使用 nftables + NFQUEUE 做预匹配；OpenWrt 官方 sing-box 包
# 也将 kmod-nft-queue 作为依赖。自装上游 .apk 时同样显式确保该能力存在。
pkg_install kmod-nft-queue || echo '提示：kmod-nft-queue 安装失败，TUN auto_redirect 将不可用。' >&2
# sing-box 优先装上游最新稳定版（apk 固件 + 架构匹配）；任何失败都回退发行版软件包，
# 保证「拿不到最新版」不会变成「装不上」。
if install_latest_singbox; then
    :
else
    pkg_install sing-box
fi
# TUN 模式需要 /dev/net/tun（OpenWrt 上通常由 kmod-tun 提供）。部分目标把 tun 编进内核、
# 没有该包，因此这里尽力而为，失败不阻断安装。
pkg_install kmod-tun >/dev/null 2>&1 || true   # 末尾注释保留，测试 05 断言本行带「|| true」
# 包管理器只保证模块「已安装」，OpenWrt 不会立刻加载它：/dev/net/tun 可能要等重启。
[ -e /dev/net/tun ] || { modprobe tun 2>/dev/null || insmod tun 2>/dev/null || true; }
[ -e /dev/net/tun ] || echo '提示：/dev/net/tun 尚未出现（模块已装），TUN 模式可能需要重启后再用。' >&2
command -v sing-box >/dev/null 2>&1 || { echo 'sing-box 安装失败。' >&2; exit 1; }

# 版本契约：feed 包是 1.12.25，而仓库默认模板要求 1.14（services[].type=api、http_clients）。
# 主版本.次版本 < 1.14 时只警告、不中止安装，避免用户对着「模板不兼容」的报错猜原因。
sb_version=$(installed_base_version)
sb_major=${sb_version%%.*}
sb_rest=${sb_version#*.}
sb_minor=${sb_rest%%.*}
case "$sb_major" in ''|*[!0-9]*) sb_major=1; sb_minor=0 ;; esac
case "$sb_minor" in ''|*[!0-9]*) sb_minor=0 ;; esac
if [ "$sb_major" -lt 1 ] || { [ "$sb_major" -eq 1 ] && [ "$sb_minor" -lt 14 ]; }; then
    echo "警告：当前内核版本 ${sb_version:-未知} 与仓库默认模板（要求 sing-box 1.14+）不兼容：请改用 1.12 兼容模板，或确保能访问 GitHub 安装上游最新版。" >&2
fi

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
        # commit 也是 || true，所以这里显式断言开关真的落盘（否则 restart 返回 0 也没进程）。
        if command -v uci >/dev/null 2>&1 && uci -q get sing-box.main >/dev/null 2>&1; then
            [ "$(uci -q get sing-box.main.enabled)" = 1 ] || {
                echo '提示：sing-box 服务的 UCI 开关未打开，服务可能不会启动。' >&2
            }
        fi
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
    # restart 的 rc 只代表「调用成功」；进程可能根本没起来（UCI 门控、配置被拒等）。
    # 慢盘/procd 调度下 1 秒不够：轮询最多 5 秒再判定，避免把「起得慢」误报成「起不来」。
    waited=0
    while [ "$waited" -lt 5 ] && ! pidof sing-box >/dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
    done
    if ! pidof sing-box >/dev/null 2>&1; then
        echo '警告：sing-box 服务未运行（restart 返回 0 但进程不存在）。' >&2
        echo '  下面这些信息能定位原因（procd 把启动失败写进系统日志，脚本这边看不到）：' >&2
        if command -v uci >/dev/null 2>&1; then
            echo "  uci show sing-box: $(uci -q show sing-box 2>/dev/null | tr '\n' ' ' | cut -c1-200)" >&2
        fi
        if command -v logread >/dev/null 2>&1; then
            echo '  logread -e sing-box（最后 10 行）:' >&2
            logread -e sing-box 2>/dev/null | tail -n 10 | sed 's/^/    /' >&2
        fi
        echo '  前台复现真实报错：/usr/bin/sing-box run -c /etc/sing-box/config.json' >&2
        # 不中止初始化：服务起不来多半是配置/模式问题，需要在菜单里修（选项 2/4/8）。
        # 若在这里 exit 1，用户每次 sb 都会卡在同一处、永远进不了菜单。
        echo '提示：安装已完成但服务未启动；初始化继续，稍后可在菜单 4 手动启动或菜单 2 重新配置。' >&2
    fi
fi
