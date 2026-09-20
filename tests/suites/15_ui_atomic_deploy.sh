#!/usr/bin/env bash
# 15_ui_atomic_deploy.sh —— 批次 2 / F8：UI 部署必须"在目标文件系统上解包 + rename"。
#
# 背景：install_ui 把压缩包解到 /tmp（交互用 $tmp、cron 生成体用 $TMP），再 mv 到
# /etc/sing-box/ui —— 两个挂载点之间是**跨设备 mv**：不是原子的 rename，中途失败还会留下
# 半成品；而失败回滚 `mv "$backup" "$UI_DIR"` 在目标已存在时会把旧 UI 移"进"半成品目录
# （旧 UI 变成 $UI_DIR/.ui-backup.XXXXXX，路径上留下的是坏的那份）。
#
# 4 处（debian/openwrt × 交互 install_ui / cron 生成体）统一改为：在 $UI_DIR 同级
# （$UI_DIR.staging）解包，部署只剩一次同文件系统 rename；回滚前显式 rm -rf 目标。
#
# 端到端行为由已有的 12_ui_install.sh（用真实 zip fixture 驱动 update_ui.sh）覆盖，
# 这里断言的是"解包位置 / 回滚顺序 / heredoc 引号"这些静态但极易回归的性质。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

suite_begin "batch2 F8: UI 部署在目标同级解包并原子 rename（4 处）"

for f in openwrt/update_ui.sh debian/update_ui.sh; do
    p="$SBSHELL_SRC/$f"
    assert_grep 'staging="\${UI_DIR}.staging"' "$p" "$f: 使用与目标同级的 staging 目录"
    assert_grep 'archive_top "\$tmp/ui.zip" "\$staging/extract"' "$p" \
        "$f: 交互路径在 staging 里解包"
    assert_grep 'archive_top "\$TMP/ui.zip" "\$staging/extract"' "$p" \
        "$f: cron 路径在 staging 里解包"
    assert_no_grep 'archive_top "\$tmp/ui.zip" "\$tmp/extract"' "$p" \
        "$f: 不再解包到 /tmp（交互路径）"
    assert_no_grep 'archive_top "\$TMP/ui.zip" "\$TMP/extract"' "$p" \
        "$f: 不再解包到 /tmp（cron 路径）"
    # 生成给 cron 的那份必须是引号 heredoc，否则 $staging/$UI_DIR 会在生成时被展开成空。
    assert_grep "update-ui.sh <<'EOF'" "$p" "$f: cron 生成体使用引号 heredoc"
done

suite_begin "batch2 F8: 回滚前先清掉半成品目标"

for f in openwrt/update_ui.sh debian/update_ui.sh; do
    p="$SBSHELL_SRC/$f"
    # 每个文件两处（交互 + cron）：先 rm -rf 目标，紧接着才是把备份搬回来。
    assert_eq "$(grep -cF 'rm -rf "$UI_DIR"' "$p")" "2" "$f: 两处回滚都先清掉目标"
    if grep -A1 -F 'rm -rf "$UI_DIR"' "$p" | grep -qF 'mv "$backup" "$UI_DIR"'; then
        pass "$f: rm -rf 目标之后紧跟 mv 备份恢复"
    else
        fail "$f: 回滚顺序不对（rm 目标之后没有恢复备份）"
    fi
done

suite_end
