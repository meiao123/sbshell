#!/usr/bin/env bash
# 23_sha256_manifest.sh —— A-12：发货脚本的 SHA256SUMS 清单与安装前完整性校验。
#
# 覆盖：
#   a) 仓库根的 SHA256SUMS 覆盖全部发货脚本，且每个哈希都与检出内容一致（等价于 CI 的防漂移步骤）
#   b) 两处 verify_script_hashes 副本（update_scripts.sh / menu.sh）逐字一致
#   c) 副本行为：哈希正确通过 / 内容被篡改失败 / 文件缺失失败 / 前缀不匹配（checked=0）失败 /
#      环境里没有 sha256sum 时按设计告警放行
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SRC="${SBSHELL_SRC:-/src}"

# ------------------------------------------------------------ a) 清单本身
suite_begin "A-12: SHA256SUMS 覆盖全部发货脚本"

assert_file "$SRC/SHA256SUMS" "仓库根存在 SHA256SUMS"

missing=0
for f in "$SRC"/openwrt/*.sh; do
    name="openwrt/$(basename "$f")"
    if ! grep -q "  ${name}$" "$SRC/SHA256SUMS"; then
        fail "清单缺少 $name"
        missing=$((missing + 1))
    fi
done
if ! grep -q '  sbshall\.sh$' "$SRC/SHA256SUMS"; then
    fail "清单缺少 sbshall.sh"
    missing=$((missing + 1))
fi
[ "$missing" -eq 0 ] && pass "清单覆盖 openwrt/ 下全部脚本与 sbshall.sh"

drift=0
while read -r hash name; do
    [ -n "$name" ] || continue
    actual=$(sha256sum "$SRC/$name" 2>/dev/null | awk '{print $1}')
    if [ "$actual" != "$hash" ]; then
        fail "哈希不符：$name（清单 $hash，实际 ${actual:-缺失}）"
        drift=$((drift + 1))
    fi
done < "$SRC/SHA256SUMS"
[ "$drift" -eq 0 ] && pass "清单里每个文件的哈希都与检出内容一致"

# ------------------------------------------------------- b) 两处副本一致
suite_begin "A-12: 两处 verify_script_hashes 副本逐字一致"

fn_one=$(awk '/^verify_script_hashes\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$SRC/openwrt/update_scripts.sh")
fn_two=$(awk '/^verify_script_hashes\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$SRC/openwrt/menu.sh")
assert_eq "$(printf '%s' "$fn_one" | sha256sum | cut -d' ' -f1)" \
    "$(printf '%s' "$fn_two" | sha256sum | cut -d' ' -f1)" "两处副本逐字一致"
assert_contains "$fn_one" 'sha256sum "$dir/$name"' "副本逐文件比对哈希"
assert_contains "$fn_one" 'SHA256SUMS 中没有本目录的条目' "副本拒绝空覆盖（checked=0 即失败）"

# 调用点：下载清单后必须校验，且校验在安装之前
assert_grep 'download_repo_file "SHA256SUMS" "main" "\$TMP_DIR/SHA256SUMS"' \
    "$SRC/openwrt/update_scripts.sh" "update_scripts.sh 会下载清单"
assert_grep 'verify_script_hashes "\$TMP_DIR/SHA256SUMS" "\$TMP_DIR" openwrt || exit 1' \
    "$SRC/openwrt/update_scripts.sh" "update_scripts.sh 校验失败即中止"
assert_grep 'verify_script_hashes "\$tmp/SHA256SUMS" "\$tmp" openwrt' \
    "$SRC/openwrt/menu.sh" "menu.sh 走同一套校验"
order=$(awk '
    /download_repo_file "SHA256SUMS"/ { dl = NR }
    /verify_script_hashes "\$TMP_DIR\/SHA256SUMS"/ { vf = NR }
    /install -o root -g root -m 0755 "\$TMP_DIR\/\$script"/ { ins = NR }
    END { if (dl && vf && ins && dl < vf && vf < ins) { print "ok" } else { print "bad" } }
' "$SRC/openwrt/update_scripts.sh")
assert_eq "$order" "ok" "顺序为：下载清单 → 校验 → 安装"

# ------------------------------------------------------------- c) 行为
suite_begin "A-12: verify_script_hashes 行为"

va=$(mktemp -d)
printf '%s\n' "$fn_one" > "$va/verify.sh"
mkdir -p "$va/scripts"
cat > "$va/driver.sh" <<'EOS'
set -uo pipefail
. "$1/verify.sh"
verify_script_hashes "$3" "$2" openwrt
echo "rc=$?"
EOS

printf 'echo hello\n' > "$va/scripts/demo.sh"
good=$(sha256sum "$va/scripts/demo.sh" | awk '{print $1}')
printf '%s  openwrt/demo.sh\n' "$good" > "$va/good.manifest"
printf '%s  openwrt/gone.sh\n' "$good" > "$va/missing.manifest"
printf '%s  openwrt/demo.sh\n' "$good" > "$va/tampered.manifest"
printf '%s  otheros/demo.sh\n' "$good" > "$va/prefix.manifest"

run_scenario() { bash "$va/driver.sh" "$va" "$va/scripts" "$1" 2>/dev/null | tail -n1; }

assert_eq "$(run_scenario "$va/good.manifest")" "rc=0" "哈希正确 → 通过"

printf 'echo tampered\n' > "$va/scripts/demo.sh"
assert_eq "$(run_scenario "$va/tampered.manifest")" "rc=1" "内容被篡改 → 拒绝"

printf 'echo hello\n' > "$va/scripts/demo.sh"
assert_eq "$(run_scenario "$va/missing.manifest")" "rc=1" "清单里的文件缺失 → 拒绝"
assert_eq "$(run_scenario "$va/prefix.manifest")" "rc=1" "清单没有本目录条目（checked=0）→ 拒绝"

# 没有 sha256sum 时按设计放行（但必须给出显式警告），否则裁剪过的 busybox 上更新会彻底坏掉。
# 注意 bash 要用绝对路径：受限 PATH 下 `env PATH=/nonexistent bash …` 会找不到解释器。
BASH_BIN=$(command -v bash)
out=$(env PATH=/nonexistent "$BASH_BIN" "$va/driver.sh" "$va" "$va/scripts" "$va/good.manifest" 2>&1 | tail -n2)
assert_contains "$out" "跳过下载内容校验" "缺少 sha256sum 时打印显式警告"
assert_contains "$out" "rc=0" "缺少 sha256sum 时放行（有意取舍，已在 docs 记录）"

rm -rf "$va"

suite_end
