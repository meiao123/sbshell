#!/usr/bin/env bash
# 35_deploy_backend.sh —— 菜单 12：本地构建并部署 sing-box-subscribe 后端（Docker）
#
# 用 docker/curl 桩覆盖五条路径（都不需要真的 Docker）：
#   1) 守护进程不可用 → 明确报错，且不做任何容器操作；
#   2) 构建失败 → 报错，且不重建容器（现有后端保持不变）；
#   3) 正常部署（跳过端到端）→ build + run 都按预期参数执行；
#   4) 健康检查失败 → 回滚到 :previous 镜像并返回非 0；
#   5) 端到端校验 → 调 /config/ 生成配置并通过 sing-box check；
#   6) --build-only → 只构建、不动容器。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

O="$SBSHELL_SRC/openwrt"
assert_file "$O/deploy_backend.sh" "存在 openwrt/deploy_backend.sh"

suite_begin "deploy_backend：脚本结构与菜链接线"

assert_grep '^#!/bin/bash' "$O/deploy_backend.sh" "使用 bash"
assert_grep '_sbshell_lib_dir/lib\.sh' "$O/deploy_backend.sh" "加载公共库"
assert_grep 'BACKEND_PIN=' "$O/deploy_backend.sh" "固定上游 commit（可复现）"
assert_grep 'docker build' "$O/deploy_backend.sh" "调用 docker build"
assert_grep 'docker run -d --name' "$O/deploy_backend.sh" "调用 docker run -d"
assert_grep '\-\-network host' "$O/deploy_backend.sh" "容器使用 host 网络"
assert_grep '^rollback_container() {' "$O/deploy_backend.sh" "实现回滚"
assert_grep '^wait_healthy() {' "$O/deploy_backend.sh" "实现健康检查"
assert_grep '^e2e_check() {' "$O/deploy_backend.sh" "实现端到端校验"
assert_grep '--build-only' "$O/deploy_backend.sh" "支持只构建模式"
assert_grep 'case "$WAIT_SECS" in' "$O/deploy_backend.sh" "健康检查等待时长做数值校验"
assert_grep '^MODE_FILE=' "$O/deploy_backend.sh" "支持模式文件（按模式选模板）"
assert_no_grep '\beval\b' "$O/deploy_backend.sh" "不使用 eval"

# ---------- 桩环境 ----------
stub_dir=$(mktemp -d)
state=$(mktemp -d)
build_root=$(mktemp -d)/build
src_parent=$(mktemp -d)
mkdir -p "$src_parent/sing-box-subscribe-test"
printf 'FROM scratch\n' > "$src_parent/sing-box-subscribe-test/Dockerfile"
printf 'flask\n' > "$src_parent/sing-box-subscribe-test/requirements.txt"

cat > "$stub_dir/docker" <<'EOS'
#!/bin/bash
S=${SBSHELL_STUB_STATE:-/tmp/sbshell-stub-state}
mkdir -p "$S" 2>/dev/null || true
printf 'docker %s\n' "$*" >> "$S/docker.log"
cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
    info) [ "${SBSHELL_TEST_INFO_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
    build) [ "${SBSHELL_TEST_BUILD_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
    image) exit 0 ;;
    inspect)
        if [ "${1:-}" = "--format" ]; then
            printf '%s\n' "${SBSHELL_TEST_PREV_IMAGE:-sbshell-backend:old}"
            exit 0
        fi
        [ "${SBSHELL_TEST_CONTAINER_EXISTS:-0}" = 1 ] && exit 0
        exit 1 ;;
    run) [ "${SBSHELL_TEST_RUN_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
    *) exit 0 ;;
esac
EOS
chmod 0755 "$stub_dir/docker"

cat > "$stub_dir/id" <<'EOS'
#!/bin/bash
# 测试桩：始终表现为 root（本地 Git Bash 上没有 sudo，容器里本来也是 root）
echo 0
EOS
chmod 0755 "$stub_dir/id"

cat > "$stub_dir/curl" <<'EOS'
#!/bin/bash
S=${SBSHELL_STUB_STATE:-/tmp/sbshell-stub-state}
mkdir -p "$S" 2>/dev/null || true
printf 'curl %s\n' "$*" >> "$S/curl.log"
out=''; wfmt=''; url=''
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="${2:-}"; shift 2 ;;
        -w) wfmt="${2:-}"; shift 2 ;;
        --connect-timeout|--max-time|--proto) shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    */archive/*)
        [ "${SBSHELL_TEST_FETCH_FAIL:-0}" = 1 ] && exit 22
        tar -czf "$out" -C "${SBSHELL_TEST_SRC_PARENT}" sing-box-subscribe-test
        exit 0 ;;
    *github.com/Toperlock*) exit 0 ;;
    */config/*)
        [ "${SBSHELL_TEST_E2E_FAIL:-0}" = 1 ] && exit 7
        if [ -n "$out" ] && [ "$out" != /dev/null ]; then printf '{}\n' > "$out"; fi
        [ -n "$wfmt" ] && printf '%s' "${SBSHELL_TEST_HTTP:-200}"
        exit 0 ;;
    *:5000/*)
        [ "${SBSHELL_TEST_HEALTH_FAIL:-0}" = 1 ] && exit 7
        if [ -n "$out" ] && [ "$out" != /dev/null ]; then printf '{}\n' > "$out"; fi
        [ -n "$wfmt" ] && printf '%s' "${SBSHELL_TEST_HTTP:-200}"
        exit 0 ;;
esac
[ -n "$wfmt" ] && printf '%s' "${SBSHELL_TEST_HTTP:-200}"
exit 0
EOS
chmod 0755 "$stub_dir/curl"

# sing-box 桩：端到端校验只在“配置非空”时才应返回成功（本地没有真机二进制，容器里也会优先用它）
cat > "$stub_dir/sing-box" <<'EOS'
#!/bin/bash
case "${1:-}" in
    check)
        shift
        f=''
        while [ $# -gt 0 ]; do case "$1" in -c) f="${2:-}"; shift 2 ;; *) shift ;; esac; done
        [ -s "$f" ] && exit 0
        exit 1 ;;
esac
exit 0
EOS
chmod 0755 "$stub_dir/sing-box"

def_file=$(mktemp)
man_file=$(mktemp)
mode_file=$(mktemp)
printf 'MODE=TUN\n' > "$mode_file"
printf 'BACKEND_URL=http://127.0.0.1:5000/\nSUBSCRIPTION_URL=http://127.0.0.1:3001/sub/download/collection/proxy?target=sing-box\nTUN_TEMPLATE_URL=https://example.test/config.json\n' > "$def_file"

deploy() { # deploy <额外env字符串> [脚本参数]...
    local st="$1"; shift
    : > "$state/docker.log"
    : > "$state/curl.log"
    if [ -n "$st" ]; then
        env PATH="$stub_dir:$PATH" SBSHELL_STUB_STATE="$state" \
            SBSHELL_BACKEND_BUILD_ROOT="$build_root" SBSHELL_BACKEND_WAIT_SECS=2 \
            SBSHELL_TEST_SRC_PARENT="$src_parent" SBSHELL_DEFAULTS_FILE="$def_file" \
            SBSHELL_MANUAL_FILE="$man_file" SBSHELL_MODE_FILE="$mode_file" $st \
            bash "$O/deploy_backend.sh" "$@" 2>&1
    else
        env PATH="$stub_dir:$PATH" SBSHELL_STUB_STATE="$state" \
            SBSHELL_BACKEND_BUILD_ROOT="$build_root" SBSHELL_BACKEND_WAIT_SECS=2 \
            SBSHELL_TEST_SRC_PARENT="$src_parent" SBSHELL_DEFAULTS_FILE="$def_file" \
            SBSHELL_MANUAL_FILE="$man_file" SBSHELL_MODE_FILE="$mode_file" \
            bash "$O/deploy_backend.sh" "$@" 2>&1
    fi
}

suite_begin "deploy_backend：失败路径不得破坏现有后端"

out=$(deploy 'SBSHELL_TEST_INFO_FAIL=1'); rc=$?
assert_not_rc "$rc" 0 "docker 守护进程不可用时返回非 0"
assert_contains "$out" '守护进程未运行' "给出守护进程不可用的原因"
if grep -q '^docker run' "$state/docker.log" 2>/dev/null; then
    fail '预检失败却仍然启动了容器'
else
    pass '预检失败时没有做任何容器操作'
fi

out=$(deploy 'SBSHELL_TEST_BUILD_FAIL=1'); rc=$?
assert_not_rc "$rc" 0 "构建失败时返回非 0"
assert_contains "$out" '镜像构建失败' "明确指出构建失败"
if grep -q '^docker run' "$state/docker.log" 2>/dev/null; then
    fail '构建失败却仍重建了容器（会弄坏现有后端）'
else
    pass '构建失败时现有容器不受影响'
fi

suite_begin "deploy_backend：成功路径与参数"

out=$(deploy 'SBSHELL_TEST_BUILD_FAIL=0 SBSHELL_TEST_CONTAINER_EXISTS=1' --skip-e2e); rc=$?
assert_rc "$rc" 0 "构建 + 部署成功"
assert_grep '^docker build --pull --network host -t sbshell-backend:' "$state/docker.log" "构建参数正确（先拉基础镜像、host 网络）"
assert_grep '^docker run -d --name sbshell-backend --network host --restart unless-stopped sbshell-backend:' "$state/docker.log" "启动参数正确"
assert_contains "$out" '后端部署完成' "输出完成提示"

: > "$state/docker.log"
out=$(deploy '' --build-only); rc=$?
assert_rc "$rc" 0 "--build-only 成功"
if grep -q '^docker run' "$state/docker.log" 2>/dev/null; then
    fail '--build-only 不应创建容器'
else
    pass '--build-only 只构建镜像'
fi

suite_begin "deploy_backend：健康检查失败回滚"

out=$(deploy 'SBSHELL_TEST_HEALTH_FAIL=1 SBSHELL_TEST_CONTAINER_EXISTS=1'); rc=$?
assert_not_rc "$rc" 0 "健康检查失败时返回非 0"
assert_grep '^docker rm -f sbshell-backend' "$state/docker.log" "失败后清理新容器"
assert_grep 'sbshell-backend:previous' "$state/docker.log" "尝试用 :previous 镜像回滚"
assert_contains "$out" '回滚' "输出回滚说明"

suite_begin "deploy_backend：端到端校验（真实订阅路径）"

out=$(deploy 'SBSHELL_TEST_HTTP=200 SBSHELL_TEST_CONTAINER_EXISTS=1'); rc=$?
assert_rc "$rc" 0 "端到端校验通过"
assert_grep '/config/' "$state/curl.log" "按后后端约定调用了 /config/ 生成配置"
assert_contains "$out" '端到端校验通过' "输出端到端通过"

out=$(deploy 'SBSHELL_TEST_HTTP=500 SBSHELL_TEST_CONTAINER_EXISTS=1'); rc=$?
assert_not_rc "$rc" 0 "后端 500 时返回非 0"
assert_contains "$out" 'HTTP 500' "报告后端 500"

suite_begin "deploy_backend：端到端校验按模式选模板，且只探测刚部署的本机后端"

def2=$(mktemp)
mode2=$(mktemp)
printf 'BACKEND_URL=http://10.0.0.9:5000/\nSUBSCRIPTION_URL=http://10.0.0.9:3001/sub?target=sing-box\nTPROXY_TEMPLATE_URL=https://example.test/tproxy.json\n' > "$def2"
printf 'MODE=TProxy\n' > "$mode2"
out=$(deploy "SBSHELL_TEST_CONTAINER_EXISTS=1 SBSHELL_DEFAULTS_FILE=$def2 SBSHELL_MODE_FILE=$mode2"); rc=$?
assert_rc "$rc" 0 "TProxy 模式端到端校验成功"
assert_grep '127\.0\.0\.1:5000/config/' "$state/curl.log" "校验的是刚部署的本机后端"
assert_grep 'tproxy\.json' "$state/curl.log" "按 TProxy 模式选用 TPROXY 模板"
if grep -q '10\.0\.0\.9:5000/' "$state/curl.log" 2>/dev/null; then
    fail '把校验请求打到了默认（远端）后端'
else
    pass '没有请求默认后端，只校验本机部署'
fi
rm -f "$def2" "$mode2"

out=$(deploy 'SBSHELL_TEST_CONTAINER_EXISTS=1 SBSHELL_TEST_E2E_FAIL=1'); rc=$?
assert_not_rc "$rc" 0 "端到端连不上后端时返回非 0"
assert_grep '^docker rm -f sbshell-backend' "$state/docker.log" "失败后清理新容器"
assert_grep 'sbshell-backend:previous' "$state/docker.log" "失败后回滚到 :previous"

rm -rf "$stub_dir" "$state" "$(dirname "$build_root")" "$src_parent" "$def_file" "$man_file" "$mode_file"
suite_end
