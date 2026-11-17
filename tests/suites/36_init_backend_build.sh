#!/usr/bin/env bash
# 36_init_backend_build.sh —— 初始化流程：UI 装完后、选模式之前自动构建本机后端
#
# 真机场景：sing-box 未安装 → 初始化一路装好，但本机后端没跑起来，
# 于是「配置文件下载」必然失败（curl 7 连接被拒绝）。这里要求初始化在 UI 之后
# 自动做一次 Docker 本地构建，并且：
#   a) 顺序正确：install_default_ui → ensure_backend_deployed → switch_mode；
#   b) 后端已健康 / 默认后端非本机 / 无 docker / 显式跳过 时都不构建；
#   c) 构建失败只告警，不阻断初始化（否则永远进不了菜单）。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

O="$SBSHELL_SRC/openwrt"
MENU="$O/menu.sh"

suite_begin "初始化：UI 之后、选模式之前自动构建本机后端"

assert_grep '^ensure_backend_deployed() {' "$MENU" "提供初始化期的后端构建函数"
assert_grep 'ensure_backend_deployed || true' "$MENU" "调用处不会把失败升级成初始化失败"
assert_grep 'SBSHELL_SKIP_BACKEND_BUILD' "$MENU" "支持显式跳过（测试/无 docker 环境）"
assert_grep 'command -v docker' "$MENU" "无 docker 时跳过而不是报错"
assert_grep '本机后端已在运行' "$MENU" "后端已健康时跳过重复构建"
assert_grep '非本机' "$MENU" "默认后端不是本机时跳过构建"
assert_grep '构建/部署失败（初始化继续）' "$MENU" "失败时明确告知初始化继续"

# 顺序断言：在 initialize() 函数体内，install_default_ui < ensure_backend_deployed < switch_mode
init_body=$(awk '/^initialize\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$MENU")
ui_ln=$(printf '%s\n' "$init_body" | grep -n 'install_default_ui' | head -n1 | cut -d: -f1 || true)
be_ln=$(printf '%s\n' "$init_body" | grep -n 'ensure_backend_deployed' | head -n1 | cut -d: -f1 || true)
sm_ln=$(printf '%s\n' "$init_body" | grep -n 'switch_mode' | head -n1 | cut -d: -f1 || true)
if [ -n "$ui_ln" ] && [ -n "$be_ln" ] && [ -n "$sm_ln" ] && [ "$ui_ln" -lt "$be_ln" ] && [ "$be_ln" -lt "$sm_ln" ]; then
    pass "顺序：install_default_ui($ui_ln) → ensure_backend_deployed($be_ln) → switch_mode($sm_ln)"
else
    fail "顺序不对：ui=$ui_ln backend=$be_ln switch_mode=$sm_ln"
fi

suite_begin "初始化后端构建：四种跳过场景与构建失败不阻断"

fn=$(mktemp)
awk '/^ensure_backend_deployed\(\)/{p=1} p{print} p&&/^}$/{exit}' "$MENU" > "$fn"
stub=$(mktemp -d)
sd=$(mktemp -d)
mark=$(mktemp)
: > "$mark"

cat > "$sd/deploy_backend.sh" <<'EOS'
#!/bin/bash
printf 'DEPLOY_RAN\n' >> "${MARK_FILE:?}"
exit "${DEPLOY_RC:-0}"
EOS
chmod 0755 "$sd/deploy_backend.sh"

cat > "$stub/docker" <<'EOS'
#!/bin/bash
exit 0
EOS
chmod 0755 "$stub/docker"

cat > "$stub/curl" <<'EOS'
#!/bin/bash
[ "${STUB_HEALTHY:-0}" = 1 ] && exit 0
exit 7
EOS
chmod 0755 "$stub/curl"

run_ensure() { # run_ensure <defaults 文件内容> [KEY=VALUE ...]
    local content="$1"; shift
    local kv
    df=$(mktemp)
    printf '%s' "$content" > "$df"
    out=$(
        (
            export CYAN='' GREEN='' YELLOW='' NC=''
            export SCRIPT_DIR="$sd" DEFAULTS_FILE="$df" MARK_FILE="$mark"
            for kv in "$@"; do export "$kv"; done
            . "$fn"
            ensure_backend_deployed
        ) 2>&1
    )
    rc=$?
    rm -f "$df"
    printf '%s' "$rc" > "$sd/last_rc"
    printf '%s' "$out"
}

: > "$mark"
out=$(run_ensure '' PATH="$stub:$PATH")
assert_contains "$out" '本机后端未运行' "本机后端未运行时会触发构建"
assert_contains "$out" '后端已就绪' "构建成功给出完成提示"
assert_grep 'DEPLOY_RAN' "$mark" "确实调用了 deploy_backend.sh"

: > "$mark"
out=$(run_ensure '' STUB_HEALTHY=1 PATH="$stub:$PATH")
assert_contains "$out" '已在运行' "后端已健康时跳过构建"
if grep -q 'DEPLOY_RAN' "$mark" 2>/dev/null; then
    fail '后端已健康却仍然重建'
else
    pass '后端已健康时没有重复构建'
fi

: > "$mark"
out=$(run_ensure 'BACKEND_URL=http://10.0.0.9:5000/
' PATH="$stub:$PATH")
assert_contains "$out" '非本机' "默认后端非本机时跳过并说明原因"
if grep -q 'DEPLOY_RAN' "$mark" 2>/dev/null; then
    fail '非本机后端却仍然本地构建'
else
    pass '非本机后端时没有本地构建'
fi

: > "$mark"
out=$(SBSHELL_SKIP_BACKEND_BUILD=1 && run_ensure '' PATH="$stub:$PATH")
assert_contains "$out" '跳过自动构建' "SBSHELL_SKIP_BACKEND_BUILD=1 时跳过"

: > "$mark"
out=$(run_ensure '' DEPLOY_RC=1 PATH="$stub:$PATH")
assert_rc "$(cat "$sd/last_rc")" 0 "构建失败时函数仍返回 0（不阻断初始化）"
assert_contains "$out" '构建/部署失败（初始化继续）' "构建失败时给出继续提示"

rm -rf "$stub" "$sd" "$fn" "$mark"
suite_end
