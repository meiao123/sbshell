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
  2) 在 Linux 主机上以 root 直接运行：tests/run.sh --local
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
