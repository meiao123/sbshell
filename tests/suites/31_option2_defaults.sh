#!/usr/bin/env bash
# 31_option2_defaults.sh
# 真机回归：菜单 6（set_defaults.sh）写好默认参数后，菜单 2（manual_update.sh）三个地址
# 提示直接回车必须能沿用已配置的地址。
#   旧实现只读 defaults.conf：选项 6 允许把用不到的字段留空（例如只填后端地址与订阅），
#   这时回车解析出空值 → validate_endpoints 打回 → 三个提示又被重新问一遍，表现为
#   「选项 6 已经设好默认地址，选项 2 直接回车却用不上」；没有 defaults.conf 时更糟：
#   后端/订阅被解析成空值并写回 manual.conf，等于把已配置的地址清掉。
# 现在解析顺序是 defaults.conf → manual.conf（当前已生效的地址）。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

MANUAL=/etc/sing-box/scripts/manual_update.sh

prepare_env() { # $1 = 当前模式
    reset_stub_state
    reset_singbox_dir
    reset_openwrt_dirs
    reset_fixtures
    install_repo_scripts openwrt
    printf 'MODE=%s\n' "$1" > /etc/sing-box/mode.conf
    printf '%s\n' "$VALID_CLIENT_CONFIG" > /etc/sing-box/config.json
    fixture_write template.json "$VALID_CLIENT_CONFIG"
}

suite_begin "选项 2：默认值缺项时回车沿用 manual.conf（TProxy 模板留空）"

prepare_env TProxy
cat > /etc/sing-box/defaults.conf <<'EOF'
BACKEND_URL=https://backend.test
SUBSCRIPTION_URL=tk?token=demo
TPROXY_TEMPLATE_URL=
TUN_TEMPLATE_URL=https://tpl.test/tun.json
EOF
cat > /etc/sing-box/manual.conf <<'EOF'
BACKEND_URL=https://old.test
SUBSCRIPTION_URL=oldtoken
TEMPLATE_URL=https://tpl.test/template.json
EOF
printf '%s\n' y '' '' '' y | run_with_timeout bash "$MANUAL" >/tmp/o31a.out 2>&1
rc=$?
assert_rc "$rc" 0 "三个提示直接回车即可完成更新（旧实现卡在 URL 校验并反复重问）"
assert_grep 'file=https://tpl.test/template.json' "$SBSHELL_STUB_STATE/curl.log" "空模板默认值回退到 manual.conf 里的已生效地址"
assert_grep '^BACKEND_URL=https://backend.test$' /etc/sing-box/manual.conf "后端地址取菜单 6 的默认值"
assert_grep '^TEMPLATE_URL=https://tpl.test/template.json$' /etc/sing-box/manual.conf "模板地址回退后写回 manual.conf"

suite_begin "选项 2：没有 defaults.conf 时回车不能被清空"

prepare_env TUN
rm -f /etc/sing-box/defaults.conf
cat > /etc/sing-box/manual.conf <<'EOF'
BACKEND_URL=https://keep.test
SUBSCRIPTION_URL=keeptoken
TEMPLATE_URL=https://tpl.test/template.json
EOF
printf '%s\n' y '' '' '' y | run_with_timeout bash "$MANUAL" >/tmp/o31b.out 2>&1
rc=$?
assert_rc "$rc" 0 "没有默认值时直接回车仍能更新"
assert_grep '^BACKEND_URL=https://keep.test$' /etc/sing-box/manual.conf "后端地址回退到 manual.conf（旧实现写回空值）"
assert_grep '^SUBSCRIPTION_URL=keeptoken$' /etc/sing-box/manual.conf "订阅地址回退到 manual.conf（旧实现写回空值）"
assert_grep '^TEMPLATE_URL=https://tpl.test/template.json$' /etc/sing-box/manual.conf "模板地址回退到 manual.conf"

suite_begin "选项 2：defaults.conf 完整时仍然优先使用它（不回归）"

prepare_env TProxy
fixture_write tproxy.json "$VALID_CLIENT_CONFIG"
cat > /etc/sing-box/defaults.conf <<'EOF'
BACKEND_URL=https://def.test
SUBSCRIPTION_URL=deftoken
TPROXY_TEMPLATE_URL=https://tpl.test/tproxy.json
TUN_TEMPLATE_URL=https://tpl.test/tun.json
EOF
cat > /etc/sing-box/manual.conf <<'EOF'
BACKEND_URL=https://old.test
SUBSCRIPTION_URL=oldtoken
TEMPLATE_URL=https://tpl.test/template.json
EOF
printf '%s\n' y '' '' '' y | run_with_timeout bash "$MANUAL" >/tmp/o31c.out 2>&1
rc=$?
assert_rc "$rc" 0 "默认值完整时回车可以更新"
assert_grep '^BACKEND_URL=https://def.test$' /etc/sing-box/manual.conf "默认值优先于 manual.conf"
assert_grep '^TEMPLATE_URL=https://tpl.test/tproxy.json$' /etc/sing-box/manual.conf "取当前模式（TProxy）的模板默认值"
assert_grep 'file=https://tpl.test/tproxy.json' "$SBSHELL_STUB_STATE/curl.log" "下载用的是默认模板地址"

suite_begin "选项 2：实现约束"

assert_grep 'resolve_default() {' "$SBSHELL_SRC/openwrt/lib.sh" "默认值解析封装在 lib.sh 的 resolve_default 里"
assert_grep 'read_value "\$2" "\$MANUAL_FILE"' "$SBSHELL_SRC/openwrt/lib.sh" "缺失的默认值回退到 manual.conf"

suite_end
