#!/usr/bin/env bash
# 宿主机护栏：仅在 `tests/run.sh --local`（在宿主机上直跑）时由 all.sh 调用。
#
# 背景：这套行为测试是按"一次性容器"设计的 —— 它会删除并重建 /etc/sing-box、
# /etc/rc.d、/etc/crontabs，把 tests/initd/* 安装成 /etc/init.d/sing-box|cron，
# suite 06 还会覆写 /etc/ssh/sshd_config。在宿主机上直跑时这些操作会直接打到
# 真实系统（历史版本只靠注释提醒，且 run.sh 在缺 docker 时正把 --local 当推荐回退）。
#
# 这里改为：跑之前整体备份下列路径，退出时恢复；原本不存在的路径在恢复时删除。
# 备份目录默认 /var/tmp/sbshell-host-backup.<时间戳>，可用 SBSHELL_LOCAL_BACKUP 覆盖。

# 测试会写入/删除的真实系统路径。
SBSHELL_HOST_PATHS=(
    /etc/sing-box
    /etc/rc.d
    /etc/crontabs
    /etc/init.d/sing-box
    /etc/init.d/cron
    /etc/init.d/sbshell-firewall
    /etc/ssh/sshd_config
    # --local 会在缺失时临时安装 tests/rc.common（OpenWrt init 脚本的 shebang 依赖它）
    /etc/rc.common
)

host_guard_dest() {
    printf '%s/%s' "$SBSHELL_LOCAL_BACKUP" "$(printf '%s' "${1#/}" | tr '/' '_')"
}

host_guard_init() {
    local stamp path dest
    stamp=$(date +%Y%m%d-%H%M%S)
    SBSHELL_LOCAL_BACKUP=${SBSHELL_LOCAL_BACKUP:-/var/tmp/sbshell-host-backup.$stamp}
    export SBSHELL_LOCAL_BACKUP
    mkdir -p "$SBSHELL_LOCAL_BACKUP" || {
        echo "无法创建备份目录 $SBSHELL_LOCAL_BACKUP，已放弃在宿主机上运行测试。" >&2
        exit 1
    }
    : > "$SBSHELL_LOCAL_BACKUP/.absent"
    for path in "${SBSHELL_HOST_PATHS[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            dest=$(host_guard_dest "$path")
            cp -a "$path" "$dest" 2>/dev/null || {
                echo "备份 $path 失败，已放弃在宿主机上运行测试（避免破坏真实系统）。" >&2
                exit 1
            }
        else
            # 原本不存在：恢复时要把测试创建出来的删掉。
            printf '%s\n' "$path" >> "$SBSHELL_LOCAL_BACKUP/.absent"
        fi
    done
    echo "--local：宿主机路径已备份到 $SBSHELL_LOCAL_BACKUP（退出时自动恢复）"
}

host_guard_restore() {
    local rc=$? path dest
    [ -n "${SBSHELL_LOCAL_BACKUP:-}" ] || return "$rc"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        rm -rf "$path"
    done < "$SBSHELL_LOCAL_BACKUP/.absent"
    for path in "${SBSHELL_HOST_PATHS[@]}"; do
        dest=$(host_guard_dest "$path")
        if [ -e "$dest" ] || [ -L "$dest" ]; then
            rm -rf "$path"
            cp -a "$dest" "$path" 2>/dev/null || echo "恢复 $path 失败（备份仍在 $SBSHELL_LOCAL_BACKUP）" >&2
        fi
    done
    echo "--local：宿主机路径已从 $SBSHELL_LOCAL_BACKUP 恢复"
    return "$rc"
}
