#!/usr/bin/env bash
# 20_inline_copies.sh —— 批次 4：内联副本的一致性（防止“修复只落在一部分副本里”）。
#
# 本仓库刻意把若干函数内联复制到每个脚本里（保持 `curl | bash` 可独立执行）。代价是副本会漂移：
# 批次 2 的 `install()` 兜底必须同时改 11 处（含 auto_update.sh 用 heredoc 生成给 cron 的那一份），
# 漏一处就是静默回归（OpenWrt 上自更新会 ETXTBSY 失败）。
#
# 事实：这些副本**不是**逐字相同的 —— 差异都在表象上（注释文案、是否 `--show-error`、
# 是否 `2>/dev/null` 静音、提示颜色），安全相关行为是一致的。因此这里断言的是
# **每份副本都必须具备的行为**（下限计数），而不是字节相等；只有确实逐字相同的两对
# （`route_default_exists`、`rule_pref_for_mark`）才断言哈希相等。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SRC="$SBSHELL_SRC"

# 抽出一个函数的函数体（仓库约定：`name() {` 起，第一个“只有空白 + }”的行止；
# 兜底副本缩进在 `if` 块里，因此起始允许前导空白）。
fn_body() {
    awk -v name="$2" '
        !p && $0 ~ ("^[[:space:]]*" name "\\(\\)[[:space:]]*\\{") { p = 1 }
        p { print }
        p && /^[[:space:]]*}$/ { exit }
    ' "$1"
}

fn_hash() { fn_body "$1" "$2" | sha256sum | cut -c1-16; }

# 断言某个模式在文件里至少出现 n 次（用于“每份副本都带这个行为”）。
assert_min_count() {
    local file="$1" pattern="$2" want="$3" desc="$4" got
    got=$(grep -c -- "$pattern" "$file" 2>/dev/null || true)
    if [ "${got:-0}" -ge "$want" ]; then
        pass "$desc"
    else
        fail "$desc (在 $file 里只出现 ${got:-0} 次，至少需要 $want)"
    fi
}

# ------------------------------------------------ install 兜底：每份副本都要有
suite_begin "inline copies: install 兜底的关键行为在每份副本里都在"

shim_files=0
for f in "$SRC"/sbshall.sh "$SRC"/openwrt/*.sh; do
    anchors=$(grep -c '^[[:space:]]*install() {' "$f" 2>/dev/null || true)
    [ "${anchors:-0}" -ge 1 ] || continue
    shim_files=$((shim_files + 1))
    rel=${f#"$SRC"/}
    # 先 rm 再写（避免覆盖正在运行的脚本导致 ETXTBSY）—— 每份副本都各有一处。
    assert_min_count "$f" 'rm -f "$2"' "$anchors" "$rel: 每份 install 兜底都先 unlink 再写"
    assert_min_count "$f" 'mkdir -p "$@"' "$anchors" "$rel: 每份兜底都支持 -d"
    assert_min_count "$f" 'chmod "$m"' "$anchors" "$rel: 每份兜底都处理 -m"
    assert_min_count "$f" 'chown "$o${g:+:$g}"' "$anchors" "$rel: 每份兜底都处理 -o/-g"
done
assert_eq "$shim_files" "10" "10 个文件内联了 install 兜底（新增下载/安装脚本时必须一并添加）"

# 用了 `install -` 却没有兜底 = 在 ImmortalWrt 上必然 command not found。
missing=''
for f in "$SRC"/sbshall.sh "$SRC"/openwrt/*.sh; do
    if grep -E '(^|[^-[:alnum:]_])install[[:space:]]+-' "$f" 2>/dev/null | grep -qvE '(opkg|apk)[[:space:]]+install'; then
        grep -q '^[[:space:]]*install() {' "$f" || missing="$missing ${f#"$SRC"/}"
    fi
done
assert_eq "$missing" "" "所有使用 install 的脚本都自带兜底$missing"

# cron 生成体：auto_update.sh 里有两份（自身 + heredoc 给 cron 的那份）。
assert_min_count "$SRC/openwrt/auto_update.sh" '^[[:space:]]*install() {' 2 \
    "auto_update.sh 的 cron 生成体里也保留了 install 兜底（漏了会让 cron 静默不更新配置）"

# ------------------------------------------------ 下载链：每份副本都只走 HTTPS
suite_begin "inline copies: 下载链的 HTTPS 与路径校验在每份副本里都在"

for rel in sbshall.sh openwrt/menu.sh openwrt/update_scripts.sh; do
    f="$SRC/$rel"
    assert_min_count "$f" "--proto '=https'" 3 "$rel: 三层下载都限定 HTTPS"
    assert_min_count "$f" '--tlsv1.2' 3 "$rel: 三层下载都要求 TLS 1.2 以上"
    assert_no_grep "proto '=http" "$f" "$rel: 不允许明文 HTTP 下载"
    assert_min_count "$f" '"\$prefix/\$path"' 1 "$rel: 归档下载按 prefix 拼条目"
done

for rel in sbshall.sh openwrt/menu.sh openwrt/update_scripts.sh; do
    f="$SRC/$rel"
    assert_min_count "$f" '\*\.\.\*\|/\*' 1 "$rel: 归档下载拒绝 .. 与绝对路径（路径穿越防护）"
    assert_min_count "$f" '\[ -s "\$output" \]' 3 "$rel: 每层下载后都校验产物非空"
done

# ------------------------------------------------ 完全一致的副本：断言哈希相同
suite_begin "inline copies: 逐字相同的副本必须保持一致"

for name in route_default_exists rule_pref_for_mark; do
    a=$(fn_hash "$SRC/openwrt/clean_nft.sh" "$name")
    b=$(fn_hash "$SRC/openwrt/configure_tproxy.sh" "$name")
    if [ -n "$a" ] && [ "$a" = "$b" ]; then
        pass "$name 在 clean_nft.sh 与 configure_tproxy.sh 中逐字相同"
    else
        fail "$name 的两份副本已经漂移（'$a' vs '$b'）—— 请同步修改或在此处说明原因"
    fi
done

suite_end
