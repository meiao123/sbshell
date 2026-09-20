#!/usr/bin/env bash
# 批次 1（安全 P0/P1）回归套件。
#
# 覆盖：
#   F1 tests/run.sh --local 不再无条件破坏宿主机（显式确认 + host_guard 备份/恢复）
#   F2 debian/setup.sh 用固定提交 SHA 校验 acme.sh，不再依赖恒假的 git verify-tag
#   F3 debian/manual_update.sh 配置落盘 0640（组缺失回落 root）
#   F4 debian/manual_update.sh 临时目录 mktemp 唯一化，且在 flock 之后创建
#   F5 openwrt 三个脚本的 URL 校验/下载收敛为 HTTPS（面板本地探活保持 http，有意）
#
# 说明：F2/F3/F4/F5 在容器内是静态断言（对应脚本需要真实 root 系统与网络）；
# F1 的"拒绝运行"是行为断言。
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib/harness.sh
. "$HERE/../lib/harness.sh"

SRC="${SBSHELL_SRC:-/src}"

# ---------------------------------------------------------------- F2 acme.sh
suite_begin "batch1 F2: acme.sh 固定提交校验（轻量标签使 verify-tag 恒假）"

setup_sh="$SRC/debian/setup.sh"
assert_grep 'ACME_COMMIT=d5fc938d80e266dba3239f54cf4665432f17c00b' "$setup_sh" \
    "acme.sh 固定到 40 位提交 SHA"
assert_grep 'rev-parse HEAD' "$setup_sh" "用下载到的提交与常量比对"
assert_no_grep 'ACME_SIGNER' "$setup_sh" "移除无法校验的 SSH 签名常量"
assert_no_grep 'allowed_signers' "$setup_sh" "不再依赖 gpg.ssh.allowedSignersFile（需 git >= 2.34）"
# 注释里保留了 "旧写法 git verify-tag 恒假" 的说明，因此只在**可执行代码**上断言。
setup_code=$(grep -v '^[[:space:]]*#' "$setup_sh")
assert_not_contains "$setup_code" "verify-tag" "可执行代码里不再调用 git verify-tag"

declared=$(awk -F= '/^ACME_COMMIT=/{print $2}' "$setup_sh")
case "$declared" in
    *[!0-9a-f]*) fail "ACME_COMMIT 必须是纯十六进制（got '$declared'）" ;;
    *) if [ "${#declared}" -eq 40 ]; then pass "ACME_COMMIT 是 40 位十六进制"; else fail "ACME_COMMIT 长度不是 40（got ${#declared}）"; fi ;;
esac

# 可选联网核对：refs/tags/3.1.5 指向同一个提交（CI 默认关闭，避免依赖外网）。
if [ "${SBSHELL_ONLINE:-0}" = 1 ]; then
    remote=$(git ls-remote https://github.com/acmesh-official/acme.sh refs/tags/3.1.5 2>/dev/null | awk '{print $1}')
    assert_eq "$remote" "$declared" "上游 refs/tags/3.1.5 与固定的提交 SHA 一致"
fi

# ------------------------------------------------- F3/F4 manual_update.sh
suite_begin "batch1 F3/F4: 配置 0640 与临时目录唯一化"

mu="$SRC/debian/manual_update.sh"
assert_grep 'CONFIG_GROUP=sing-box' "$mu" "定义 CONFIG_GROUP"
assert_grep 'getent group sing-box' "$mu" "组存在用 sing-box，缺失回落 root"
assert_grep 'm 0640' "$mu" "配置以 0640 落盘"
assert_no_grep 'm 0644' "$mu" "不再用世界可读的 0644 写配置"
assert_grep 'mktemp -d /tmp/sbshell-config.XXXXXX' "$mu" "临时目录用 mktemp 唯一化"
assert_no_grep 'TMP_DIR=/tmp/sbshell-config$' "$mu" "不再使用固定可预测的临时目录"

# 顺序断言：临时目录必须在取得 flock 之后创建（并发实例不会互相删除目录）。
order=$(awk '
    /^flock -x 9$/ { lock = NR }
    /mktemp -d \/tmp\/sbshell-config\.XXXXXX/ { tmp = NR }
    END { if (lock && tmp && tmp > lock) { print "yes" } else { print "no" } }
' "$mu")
assert_eq "$order" "yes" "临时目录在 flock -x 9 之后创建"

# -------------------------------------------------------- F5 仅 HTTPS
suite_begin "batch1 F5: OpenWrt 配置 URL 仅允许 HTTPS"

for f in manual_input.sh manual_update.sh set_defaults.sh; do
    assert_grep 'valid_url() { \[\[ "\$1" =~ \^https://' "$SRC/openwrt/$f" \
        "openwrt/$f 的 URL 校验只接受 https"
done
assert_no_grep "proto '=http,https'" "$SRC/openwrt/manual_input.sh" \
    "配置下载不再允许明文 HTTP"
assert_grep "proto '=https'" "$SRC/openwrt/manual_input.sh" "配置下载使用 https"
assert_grep "proto '=http,https'" "$SRC/openwrt/update_ui.sh" \
    "面板本地探活仍允许 http（有意）"

# --------------------------------------------------- F1 宿主机护栏
suite_begin "batch1 F1: --local 不再无条件破坏宿主机"

assert_grep 'SBSHELL_ALLOW_LOCAL_DESTRUCTIVE' "$SRC/tests/run.sh" "run.sh 要求显式确认"
assert_grep 'SBSHELL_LOCAL=1' "$SRC/tests/run.sh" "--local 导出 SBSHELL_LOCAL"
assert_file "$SRC/tests/lib/host_guard.sh" "存在宿主机备份/恢复护栏"
assert_grep 'host_guard_init' "$SRC/tests/all.sh" "all.sh 在 local 模式初始化护栏"
assert_grep 'host_guard_restore' "$SRC/tests/all.sh" "all.sh 注册退出恢复"
assert_grep '/etc/ssh/sshd_config' "$SRC/tests/lib/host_guard.sh" "护栏覆盖 sshd_config"
assert_grep '/etc/sing-box' "$SRC/tests/lib/host_guard.sh" "护栏覆盖 /etc/sing-box"

# 行为断言：未显式确认时 --local 必须拒绝（且不触碰任何真实路径）。
out=$(run_with_timeout env -u SBSHELL_ALLOW_LOCAL_DESTRUCTIVE bash "$SRC/tests/run.sh" --local 2>&1)
rc=$?
assert_rc "$rc" 1 "未确认时 --local 拒绝运行"
assert_contains "$out" "SBSHELL_ALLOW_LOCAL_DESTRUCTIVE=1" "拒绝信息给出显式确认方式"
assert_contains "$out" "/etc/ssh/sshd_config" "拒绝信息列出会被覆写的真实路径"

suite_end
