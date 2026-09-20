#!/usr/bin/env bash
# 21_busybox_compat.sh —— 批次 3：busybox 兼容性护栏。
#
# 真机（OpenWrt/ImmortalWrt）的 /bin/sh 是 busybox ash，且不少 GNU 选项/命令并不存在；
# 而 CI 的 Debian 镜像装着 GNU coreutils，这类问题**在测试里看不到** —— 第一轮真机的
# `install: command not found` 就是这么漏掉的（测试镜像装了 coreutils，install 一直在）。
#
# 本套件把“经盘点/上游源码确认的干净状态”固化成断言，防止以后引入 GNU 专有用法：
#   1) shebang 只能是 #!/bin/bash 或 #!/bin/sh；
#   2) #!/bin/sh 的脚本里不得出现 bash 专有语法（pipefail、`[[ ]]`、`<<<`、数组 `+=(`、
#      `function` 关键字）—— busybox ash 会直接报错；
#   3) 不得使用 GNU 专有选项（sort -V、date -d、grep -P/-oP、readlink -f、cp --parents、
#      find -printf、xargs -r、stat --format、du -b、seq -w）；
#   4) 不得把 timeout 当外部命令调用（busybox 不保证提供该 applet；脚本里的 16 处
#      “timeout” 全是 curl 的 --connect-timeout，本断言只匹配真正的命令调用）；
#   5) stat -c 的格式串只能是 %Y（上游 busybox coreutils/stat.c 的 usage 明确写着
#      “%Y Time of last modification as seconds since Epoch”，实现里是
#      `} else if (m == 'Y') {`，所以锁过期判断在 busybox 上是可用的）；
#   6) unzip/zipinfo 缺失时必须自动安装（update_ui.sh 的 pkg_install unzip）。
#
# 说明：注释里的提法不算违规（例如 configure_tproxy.sh 在注释里解释 pipefail 的影响），
# 因此所有检查都在“去掉整行注释”的代码行上做 —— 之前用整篇文本匹配时被注释骗过两次。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SRC="${SBSHELL_SRC:-/src}"

owrt_files() {
    printf '%s\n' "$SRC/sbshall.sh"
    for f in "$SRC"/openwrt/*.sh; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
}

# 去掉整行注释后的代码行。
code_lines() { grep -v '^[[:space:]]*#' "$1"; }

rel() { printf '%s' "${1#"$SRC"/}"; }

suite_begin "busybox: shebang 合法，且 #!/bin/sh 的脚本是 POSIX"

while IFS= read -r f; do
    first=$(head -n1 "$f")
    case "$first" in
        '#!/bin/bash'|'#!/bin/sh') pass "$(rel "$f"): shebang $first" ;;
        *) fail "$(rel "$f"): shebang 既不是 bash 也不是 sh（$first）" ;;
    esac
    if [ "$first" = '#!/bin/sh' ]; then
        bad=$(code_lines "$f" | grep -nE '(^|[^[:alnum:]_])\[\[ |pipefail|<<<|\+=\(|^[[:space:]]*function ' || true)
        if [ -z "$bad" ]; then
            pass "$(rel "$f"): 作为 #!/bin/sh 不含 bash 专有语法"
        else
            fail "$(rel "$f"): #!/bin/sh 却含 bash 专有语法 -> $bad"
        fi
    fi
done < <(owrt_files)

suite_begin "busybox: 不使用 GNU 专有选项，也不把 timeout 当命令"

gnu_opts='sort -V|date -d |date --date|grep -P|grep -oP|readlink -f|cp --parents|find .*-printf|xargs -r|xargs -0|stat --format|du -b|seq -w|sha256sum --|tail -f'
timeout_cmd='(^|[^[:alnum:]_:-])timeout[[:space:]]+(-k[[:space:]]+[0-9]+[[:space:]]+)?[0-9]'

while IFS= read -r f; do
    hits=$(code_lines "$f" | grep -nE "$gnu_opts" || true)
    if [ -z "$hits" ]; then
        pass "$(rel "$f"): 无 GNU 专有选项"
    else
        fail "$(rel "$f"): 使用了 GNU 专有选项 -> $hits"
    fi
    hits=$(code_lines "$f" | grep -nE "$timeout_cmd" || true)
    if [ -z "$hits" ]; then
        pass "$(rel "$f"): 未把 timeout 当外部命令调用"
    else
        fail "$(rel "$f"): 依赖 busybox 不保证提供的 timeout 命令 -> $hits"
    fi
done < <(owrt_files)

suite_begin "busybox: stat -c 只用上游确认支持的 %Y"

while IFS= read -r f; do
    fmts=$(code_lines "$f" | grep -oE 'stat -c %[A-Za-z]+' | sort -u || true)
    [ -n "$fmts" ] || continue
    if [ "$fmts" = 'stat -c %Y' ]; then
        pass "$(rel "$f"): stat -c 只用 %Y"
    else
        fail "$(rel "$f"): stat -c 使用了未确认的格式串 -> $fmts"
    fi
done < <(owrt_files)

suite_begin "busybox: unzip 按需安装，且不再要求 zipinfo（A-13）"

ui="$SRC/openwrt/update_ui.sh"
assert_grep 'ensure_unzip()' "$ui" "有按需安装 unzip 的辅助函数"
assert_grep 'pkg_install unzip' "$ui" "缺失时仍会安装 unzip"
assert_no_grep 'command -v zipinfo' "$ui" "不再探测 zipinfo（改用同一二进制的 unzip -Z -l）"
assert_grep 'unzip -Z -l' "$ui" "列表主路径是 unzip -Z -l，zipinfo 仅作回退"
assert_grep 'ensure_curl()' "$ui" "curl 缺失时的安装走可诊断的函数（不再让 set -e 带走脚本）"

suite_end
