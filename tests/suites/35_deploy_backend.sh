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
assert_grep 'PULL_MODE' "$O/deploy_backend.sh" "registry 不可达时退出强制 --pull"
assert_grep 'BUILD_TIMEOUT' "$O/deploy_backend.sh" "脚本级构建超时"
assert_grep '构建进行中' "$O/deploy_backend.sh" "构建期间打印心跳"
assert_grep 'registry-1\.docker\.io' "$O/deploy_backend.sh" "预检探测 Docker registry"
assert_grep 'timeout "\$BUILD_TIMEOUT" docker build' "$O/deploy_backend.sh" "用 timeout 兜住 docker build"
assert_grep 'redact_url "\$sub"' "$O/deploy_backend.sh" "5xx 报错里的订阅地址脱敏（不回显 token）"
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
    build) [ "${SBSHELL_TEST_BUILD_FAIL:-0}" = 1 ] && { sleep "${SBSHELL_TEST_BUILD_SLEEP:-0}"; exit 1; }
           [ -n "${SBSHELL_TEST_BUILD_SLEEP:-}" ] && sleep "$SBSHELL_TEST_BUILD_SLEEP"
           exit 0 ;;
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
    */commits/main.atom)
        printf '<feed><id>tag:github.com,2008:Grit::Commit/%s</id></feed>\n' "${SBSHELL_TEST_UPSTREAM_SHA:-25f9fd20d2c51420f8ef378e6d211f5937ad1caf}"
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
ref_file=$(mktemp)
: > "$ref_file"
printf 'BACKEND_URL=http://127.0.0.1:5000/\nSUBSCRIPTION_URL=http://127.0.0.1:3001/sub/download/collection/proxy?target=sing-box\nTUN_TEMPLATE_URL=https://example.test/config.json\n' > "$def_file"

deploy() { # deploy <额外env字符串> [脚本参数]...
    local st="$1"; shift
    : > "$state/docker.log"
    : > "$state/curl.log"
    if [ -n "$st" ]; then
        env PATH="$stub_dir:$PATH" SBSHELL_STUB_STATE="$state" \
            SBSHELL_BACKEND_BUILD_ROOT="$build_root" SBSHELL_BACKEND_WAIT_SECS=2 \
            SBSHELL_TEST_SRC_PARENT="$src_parent" SBSHELL_DEFAULTS_FILE="$def_file" \
            SBSHELL_MANUAL_FILE="$man_file" SBSHELL_MODE_FILE="$mode_file" SBSHELL_BACKEND_REF_FILE="$ref_file" $st \
            bash "$O/deploy_backend.sh" "$@" 2>&1
    else
        env PATH="$stub_dir:$PATH" SBSHELL_STUB_STATE="$state" \
            SBSHELL_BACKEND_BUILD_ROOT="$build_root" SBSHELL_BACKEND_WAIT_SECS=2 \
            SBSHELL_TEST_SRC_PARENT="$src_parent" SBSHELL_DEFAULTS_FILE="$def_file" \
            SBSHELL_MANUAL_FILE="$man_file" SBSHELL_MODE_FILE="$mode_file" SBSHELL_BACKEND_REF_FILE="$ref_file" \
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
assert_contains "$out" '127.0.0.1:3001/***' "5xx 报错里的订阅地址已脱敏"
case "$out" in
    *'/sub/download'*) fail '5xx 报错回显了订阅 token' ;;
    *) pass '5xx 报错没有回显订阅 token' ;;
esac

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

suite_begin "deploy_backend：构建有超时、有心跳，registry 不可达时不强制 --pull"

out=$(deploy 'SBSHELL_TEST_CONTAINER_EXISTS=1 SBSHELL_TEST_BUILD_SLEEP=4 SBSHELL_BACKEND_BUILD_TIMEOUT=2 SBSHELL_BACKEND_BUILD_HEARTBEAT=1' --skip-e2e); rc=$?
assert_not_rc "$rc" 0 "构建超时返回非 0"
assert_contains "$out" '构建超时' "超时给出明确原因"
if grep -q '^docker run' "$state/docker.log" 2>/dev/null; then
    fail '构建超时却仍然启动了容器'
else
    pass '构建超时时不会重建容器'
fi

out=$(deploy 'SBSHELL_TEST_CONTAINER_EXISTS=1 SBSHELL_TEST_BUILD_SLEEP=2 SBSHELL_BACKEND_BUILD_HEARTBEAT=1' --skip-e2e); rc=$?
assert_rc "$rc" 0 "长构建（非超时）最终成功"
assert_contains "$out" '构建进行中…' "构建期间打印心跳而不是静默"

out=$(deploy 'SBSHELL_TEST_CONTAINER_EXISTS=1 SBSHELL_TEST_HTTP=000' --skip-e2e); rc=$?
assert_rc "$rc" 0 "registry 不可达时仍能构建（用本地缓存的基础镜像）"
assert_contains "$out" 'registry 不可达' "明确告知不强制 --pull 的原因"
if grep -q '^docker build --pull' "$state/docker.log" 2>/dev/null; then
    fail 'registry 不可达却仍然强制 --pull'
else
    pass 'registry 不可达时没有传 --pull'
fi
assert_grep '^docker build --network host -t sbshell-backend:' "$state/docker.log" "构建参数其余不变"

suite_begin "deploy_backend：数值环境变量的 0 值不会把事情弄坏"

assert_grep '\[ "\$WAIT_SECS" -gt 0 \] || WAIT_SECS=60' "$O/deploy_backend.sh" "WAIT_SECS=0 回退默认（否则健康检查一轮不跑就误回滚）"
assert_grep '\[ "\$BUILD_TIMEOUT" -gt 0 \] || BUILD_TIMEOUT=1800' "$O/deploy_backend.sh" "BUILD_TIMEOUT=0 回退默认"
assert_grep '\[ "\$BUILD_HEARTBEAT" -gt 0 \] || BUILD_HEARTBEAT=30' "$O/deploy_backend.sh" "BUILD_HEARTBEAT=0 回退默认（否则取模除零）"

out=$(deploy 'SBSHELL_TEST_CONTAINER_EXISTS=1 SBSHELL_BACKEND_WAIT_SECS=0' --skip-e2e); rc=$?
assert_rc "$rc" 0 "WAIT_SECS=0 时仍能通过健康检查"
# 成功路径本身也会 `docker tag ... :previous`（备份用），只有「rollback 的 docker run」才算误回滚。
if grep -q '^docker run .*:previous' "$state/docker.log" 2>/dev/null; then
    fail 'WAIT_SECS=0 把健康的后端回滚了'
else
    pass 'WAIT_SECS=0 不会误回滚'
fi

out=$(deploy 'SBSHELL_TEST_CONTAINER_EXISTS=1 SBSHELL_TEST_BUILD_SLEEP=2 SBSHELL_BACKEND_BUILD_HEARTBEAT=0' --skip-e2e); rc=$?
assert_rc "$rc" 0 "BUILD_HEARTBEAT=0 时构建仍然成功"
case "$out" in
    *'division by 0'*) fail '出现除零错误' ;;
    *) pass '没有除零错误' ;;
esac

suite_begin "deploy_backend：ref 覆盖 / 版本报告 / 切换提醒"

assert_grep 'SBSHELL_BACKEND_REF' "$O/deploy_backend.sh" "支持环境变量覆盖默认 ref"
assert_grep 'REF_STATE_FILE' "$O/deploy_backend.sh" "记录已部署 ref"
assert_grep '^upstream_latest_sha() {' "$O/deploy_backend.sh" "用 atom feed 查上游最新"
assert_grep '^report_versions() {' "$O/deploy_backend.sh" "构建前打印版本信息"
assert_grep '^warn_ref_switch() {' "$O/deploy_backend.sh" "切换 ref 时给出提醒"
assert_grep '^record_ref() {' "$O/deploy_backend.sh" "部署成功后记录 ref"

: > "$ref_file"
out=$(deploy 'SBSHELL_TEST_UPSTREAM_SHA=25f9fd20d2c51420f8ef378e6d211f5937ad1caf' --build-only); rc=$?
assert_rc "$rc" 0 "默认构建成功"
assert_contains "$out" '与固定版本一致' "上游与固定版本一致时会说明"
assert_eq "$(cat "$ref_file")" "" "仅构建模式不写 ref 状态"

out=$(deploy 'SBSHELL_TEST_UPSTREAM_SHA=0123456789abcdef0123456789abcdef01234567' --build-only); rc=$?
assert_rc "$rc" 0 "上游更新时仍能构建"
assert_contains "$out" '已落后' "提醒固定版本已落后"
assert_contains "$out" '0123456' "打印上游最新短 SHA"

printf 'abcdef0123456789abcdef0123456789abcdef01\n' > "$ref_file"
out=$(deploy 'SBSHELL_TEST_UPSTREAM_SHA=25f9fd20d2c51420f8ef378e6d211f5937ad1caf' --build-only); rc=$?
assert_contains "$out" '将切换为' "上次 ref 与本次不同会提醒"
assert_contains "$out" 'abcdef0' "提醒里带上当前运行的短 SHA"

: > "$ref_file"
out=$(deploy 'SBSHELL_BACKEND_REF=main SBSHELL_TEST_CONTAINER_EXISTS=1' --skip-e2e); rc=$?
assert_rc "$rc" 0 "SBSHELL_BACKEND_REF=main 构建部署成功"
assert_grep 'sbshell-backend:main' "$state/docker.log" "镜像 tag 使用 main"
assert_grep 'main\.tar\.gz' "$state/curl.log" "拉取的是 main 分支源码"
assert_eq "$(cat "$ref_file")" "main" "部署成功后记录 ref=main"

: > "$ref_file"
out=$(deploy 'SBSHELL_TEST_CONTAINER_EXISTS=1' --skip-e2e); rc=$?
assert_rc "$rc" 0 "默认 ref 部署成功"
assert_eq "$(cat "$ref_file")" "25f9fd20d2c51420f8ef378e6d211f5937ad1caf" "部署成功后记录固定版本"

rm -rf "$stub_dir" "$state" "$(dirname "$build_root")" "$src_parent" "$def_file" "$man_file" "$mode_file" "$ref_file"
suite_end
