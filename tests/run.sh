#!/usr/bin/env bash
# 容器化行为测试入口。
#
#   tests/run.sh            构建镜像并在容器里跑全部行为测试（推荐 / CI 使用）
#   tests/run.sh --local    在本地 Linux 主机上直接跑（需要 root，会写入 /etc/sing-box）
#
# 需要 docker 或 podman。测试只挂载仓库（只读，/src），不会修改你的工作区。
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=sbshell-tests:latest

MODE=container
case "${1:-}" in
    --local) MODE=local ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
esac

if [ "$MODE" = local ]; then
    [ "$(uname -s)" = Linux ] || { echo "--local 仅支持 Linux 主机。" >&2; exit 1; }
    [ "$(id -u)" -eq 0 ] || { echo "--local 需要 root（测试会写入 /etc/sing-box）。" >&2; exit 1; }
    # --local 直接在**这台主机**上模拟安装，会删除并覆盖下列真实路径。
    # 必须显式确认才运行；确认后由 tests/lib/host_guard.sh 备份并在退出时恢复。
    cat >&2 <<'EOF'
--local 会直接在这台主机上执行下列破坏性操作：
  - 删除并重建 /etc/sing-box（含 config.json 凭据与已安装的脚本）
  - 删除并重建 /etc/rc.d、/etc/crontabs
  - 覆盖 /etc/init.d/sing-box、/etc/init.d/cron，删除 /etc/init.d/sbshell-firewall
  - 覆写 /etc/ssh/sshd_config（suite 06 会写入两行测试配置）
测试开始前会把上述路径整体备份到 SBSHELL_LOCAL_BACKUP（默认 /var/tmp/sbshell-host-backup.<时间戳>），
退出时自动恢复；但被 kill -9 / 断电时仍可能残留，因此**请只在一次性容器或虚拟机里使用**。
确请显式确认：SBSHELL_ALLOW_LOCAL_DESTRUCTIVE=1 tests/run.sh --local
EOF
    [ "${SBSHELL_ALLOW_LOCAL_DESTRUCTIVE:-0}" = 1 ] || {
        echo "已拒绝在宿主机上运行破坏性测试（未设置 SBSHELL_ALLOW_LOCAL_DESTRUCTIVE=1）。" >&2
        exit 1
    }
    export SBSHELL_LOCAL=1
    export SBSHELL_SRC="$REPO"
    export SBSHELL_TEST_ROOT="$REPO/tests"
    exec bash "$REPO/tests/all.sh"
fi

ENGINE=''
for candidate in docker podman; do
    if command -v "$candidate" >/dev/null 2>&1; then ENGINE="$candidate"; break; fi
done
if [ -z "$ENGINE" ]; then
    cat >&2 <<'EOF'
未找到 docker 或 podman，无法运行容器化行为测试。

可选做法：
  1) 安装 docker / podman 后重新执行 tests/run.sh；
  2) 在一次性容器/虚拟机里以 root 直接运行：
     SBSHELL_ALLOW_LOCAL_DESTRUCTIVE=1 tests/run.sh --local
     （--local 会删除并覆写真实 /etc 路径，未显式确认时会被拒绝）
  3) 走 CI：.github/workflows/shell-static-check.yml 会在 GitHub runner（自带 docker）上执行。
EOF
    exit 127
fi

echo "==> 构建测试镜像 ($ENGINE)"
"$ENGINE" build -t "$IMAGE" "$REPO/tests"

echo "==> 运行行为测试"
exec "$ENGINE" run --rm \
    -v "$REPO":/src:ro \
    -e SBSHELL_SRC=/src \
    "$IMAGE" /opt/tests/all.sh "$@"
