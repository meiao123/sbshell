#!/usr/bin/env bash
# 14_batch2_integrity.sh —— 批次 2（数据完整性）回归套件。
#
# F6  11 处 install() 兜底必须先 unlink 再写：旧写法 cp -f 是就地覆盖（同 inode），
#     而 openwrt/update_scripts.sh 的下载清单里包含正在运行的 update_scripts.sh 自己
#     与父进程 menu.sh —— 在 Linux 上写正在执行的脚本会 ETXTBSY 失败，自更新必然中断。
# F7  openwrt/auto_update.sh 生成给 cron 的脚本：配置替换必须原子（同目录临时文件 + mv），
#     且回滚备份必须放在 $TMP 之外 —— $TMP 会被 cleanup() 在 EXIT 时 rm -rf，
#     而那份备份是失败路径上唯一的回滚依据（旧代码退出即销毁）。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

SCRIPTS=/etc/sing-box/scripts

# ------------------------------------------------------------------ F6 静态
suite_begin "batch2 F6: install() 兜底先 rm 再 cp（避免就地覆盖运行中的脚本）"

for f in sbshall.sh openwrt/menu.sh openwrt/update_scripts.sh openwrt/auto_update.sh \
         openwrt/configure_tun.sh openwrt/configure_tproxy.sh openwrt/manual_input.sh \
         openwrt/manual_update.sh openwrt/set_defaults.sh openwrt/switch_mode.sh; do
    assert_grep 'rm -f "\$2" 2>/dev/null || true' "$SBSHELL_SRC/$f" "$f: 兜底先 unlink 再写"
done

shim_order=$(awk '
    /rm -f "\$2"/ { rm = NR }
    /cp -f "\$1" "\$2"/ { cp = NR }
    END { if (rm && cp && rm < cp) { print "yes" } else { print "no" } }
' "$SBSHELL_SRC/sbshall.sh")
assert_eq "$shim_order" "yes" "sbshall.sh: rm 在 cp 之前"

# ------------------------------------------------------------------ F6 行为
suite_begin "batch2 F6: 替换脚本产生新 inode（行为断言）"

reset_stub_state
reset_singbox_dir
install_repo_scripts openwrt

awk '/^# --- busybox 兼容/{p=1} p{print} p&&/^fi$/{exit}' "$SCRIPTS/menu.sh" > /tmp/b2-shim.sh
if grep -q 'command -v install' /tmp/b2-shim.sh; then
    pass "从已安装的 openwrt/menu.sh 抽到 install 兜底块"
else
    fail "无法抽到 install 兜底块"
fi

printf 'old-content\n' > /tmp/b2-replace-dst
printf 'new-content\n' > /tmp/b2-replace-src
# 用硬链接判定"是否就地改写"：就地写会同时改到 .link（同一个 inode），
# 而先 unlink 再写会让路径指向新 inode、.link 保持旧内容。
# 注意不能用 stat -c %i 比较：overlayfs/tmpfs 上删除后立即重建极易复用同一个 inode 号。
rm -f /tmp/b2-replace-dst.link
ln /tmp/b2-replace-dst /tmp/b2-replace-dst.link

cat > /tmp/b2-shim-run.sh <<'EOS'
set -uo pipefail
. /tmp/b2-shim.sh
if [ "$(type -t install)" != "function" ]; then
    echo "not-a-function"
    exit 9
fi
install -m 0644 /tmp/b2-replace-src /tmp/b2-replace-dst
EOS

# 必须在"没有 install"的 PATH 下跑，否则兜底块里的 `command -v install` 为真、函数根本不会定义，
# 断言就会测到系统的 GNU install（它本来就换 inode）—— 那就是假绿。
NOPATH=$(path_without_install)
shim_out=$(PATH="$NOPATH" bash /tmp/b2-shim-run.sh 2>&1)
shim_rc=$?

assert_rc "$shim_rc" 0 "受限 PATH 下兜底 install 调用成功"
assert_not_contains "$shim_out" "not-a-function" "断言对象确实是兜底函数而非 GNU install"
assert_eq "$(cat /tmp/b2-replace-dst)" "new-content" "目标路径已是新内容"
assert_eq "$(stat -c %a /tmp/b2-replace-dst)" "644" "-m 0644 生效"
assert_eq "$(cat /tmp/b2-replace-dst.link)" "old-content" "旧 inode 未被就地改写（硬链接仍指向旧内容）"

# ------------------------------------------------------------------ F7 静态
suite_begin "batch2 F7: cron 更新脚本原子替换配置，备份活过 EXIT trap"

au="$SBSHELL_SRC/openwrt/auto_update.sh"
assert_grep 'BACKUP_FILE=/etc/sing-box/config.json.bak' "$au" "回滚备份路径在 \$TMP 之外"
assert_no_grep 'TMP/config.backup' "$au" "不再把唯一回滚来源放进会被 EXIT 清理的 \$TMP"
assert_grep 'mv -f "\$NEW_CONFIG" "\$CONFIG_FILE"' "$au" "同目录临时文件 + mv 原子替换配置"

# ------------------------------------------------------------------ F7 行为
suite_begin "batch2 F7: cron 更新后留下可回滚的 config.json.bak（行为）"

reset_stub_state
reset_singbox_dir
reset_openwrt_dirs
reset_fixtures
install_repo_scripts openwrt
for f in "$SBSHELL_SRC"/openwrt/*.sh; do cp "$f" "$SBSHELL_FIXTURES/"; done

# pidof 桩以这个文件判断"服务在跑"：先造成功场景。
: > "$SBSHELL_STUB_STATE/singbox_active"
fixture_write template.json "$VALID_CLIENT_CONFIG"
cat > /etc/sing-box/manual.conf <<'EOS'
BACKEND_URL=https://backend.test
SUBSCRIPTION_URL=tk?token=demo
TEMPLATE_URL=https://tpl.test/template.json
EOS
printf 'OLD-CONFIG\n' > /etc/sing-box/config.json

printf '1\n12\n' | run_with_timeout bash "$SCRIPTS/auto_update.sh" >/dev/null 2>&1 || true
assert_file /etc/sing-box/update-singbox.sh "生成 cron 更新脚本"

run_with_timeout bash /etc/sing-box/update-singbox.sh > /tmp/b2-cron-ok.out 2>&1
cron_rc=$?
assert_rc "$cron_rc" 0 "服务在跑时 cron 更新成功"
assert_file /etc/sing-box/config.json.bak "更新后仍保留 config.json.bak（旧代码会随 \$TMP 一起删掉）"
assert_eq "$(cat /etc/sing-box/config.json.bak)" "OLD-CONFIG" "备份内容是本次更新前的配置"
assert_not_contains "$(cat /etc/sing-box/config.json)" "OLD-CONFIG" "config.json 已替换为新配置"

# 失败场景：服务起不来（重启返回非 0）时必须回滚到本次更新前的配置。
# 注意：不能靠删 $SBSHELL_STUB_STATE/singbox_active 来制造失败 —— tests/initd/sing-box 的
# start() 自己会 touch 这个标志，restart 之后 pidof 一定成功。这里直接换成一个必定失败的服务脚本。
printf 'PRE-RESTORE\n' > /etc/sing-box/config.json
cat > /etc/init.d/sing-box <<'EOS'
#!/bin/sh
echo 'simulated restart failure' >&2
exit 1
EOS
chmod 0755 /etc/init.d/sing-box
run_with_timeout bash /etc/sing-box/update-singbox.sh > /tmp/b2-cron-fail.out 2>&1
cron_fail_rc=$?
assert_not_rc "$cron_fail_rc" 0 "服务起不来时 cron 脚本返回非 0"
assert_eq "$(cat /etc/sing-box/config.json)" "PRE-RESTORE" "失败后回滚到本次更新前的配置"
assert_file /etc/sing-box/config.json.bak "回滚备份仍在（供人工再次使用）"

suite_end
