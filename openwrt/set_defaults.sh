#!/bin/bash
set -Eeuo pipefail

# 公共实现（install 兜底、URL 校验、锁、原子提交）集中在 lib.sh，避免多处副本漂移。
_sbshell_lib_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$_sbshell_lib_dir/lib.sh" || { echo '缺少 lib.sh，请先在菜单 9 更新脚本。' >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
DEFAULTS_FILE=/etc/sing-box/defaults.conf
# 后端/订阅/TUN 模板的出厂值集中在 lib.sh（factory_default），这里只负责展示与落盘。
install -d -m 0755 /etc/sing-box

# 展示优先级：已保存的值 > 出厂值。用户在本轮输入的值会覆盖两者——所以再执行一次菜单 6
# 就能改掉默认地址；直接回车则保持当前生效值（首次运行即出厂值）。
def_backend=$(read_value BACKEND_URL "$DEFAULTS_FILE"); def_backend=${def_backend:-$(factory_default BACKEND_URL)}
def_subscription=$(read_value SUBSCRIPTION_URL "$DEFAULTS_FILE"); def_subscription=${def_subscription:-$(factory_default SUBSCRIPTION_URL)}
def_tproxy=$(read_value TPROXY_TEMPLATE_URL "$DEFAULTS_FILE")
def_tun=$(read_value TUN_TEMPLATE_URL "$DEFAULTS_FILE"); def_tun=${def_tun:-$(factory_default TUN_TEMPLATE_URL)}

read -rp "请输入后端地址 [回车使用默认: ${def_backend:-无}]: " BACKEND_URL; BACKEND_URL=${BACKEND_URL:-$def_backend}
read -rp "请输入订阅地址 [回车使用默认: ${def_subscription:-无}]: " SUBSCRIPTION_URL; SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-$def_subscription}
read -rp "请输入TProxy配置文件地址 [回车使用默认: ${def_tproxy:-无}]: " TPROXY_TEMPLATE_URL; TPROXY_TEMPLATE_URL=${TPROXY_TEMPLATE_URL:-$def_tproxy}
read -rp "请输入TUN配置文件地址 [回车使用默认: ${def_tun:-无}]: " TUN_TEMPLATE_URL; TUN_TEMPLATE_URL=${TUN_TEMPLATE_URL:-$def_tun}

for value in "$BACKEND_URL" "$TPROXY_TEMPLATE_URL" "$TUN_TEMPLATE_URL"; do
    [ -z "$value" ] || valid_url "$value" || { echo '所有配置 URL 必须是 http:// 或 https:// 的地址。' >&2; exit 1; }
    [ -z "$value" ] || warn_plaintext_http "$value"
done
[ -n "$SUBSCRIPTION_URL" ] || { echo '订阅地址不能为空。' >&2; exit 1; }
# 订阅地址里的空白、`#`、`&file=` 会破坏下游解析；printf 不做转义，含换行的粘贴会在
# defaults.conf 里插出额外的 KEY=value 行（下游按行取值），因此必须先校验、再落盘。
valid_subscription "$SUBSCRIPTION_URL" || { echo '订阅地址包含非法字符（空白、# 或 &file=）。' >&2; exit 1; }

# 原子提交：内容先写同目录临时文件，再交给 commit_file（lib.sh）：install 到同目录、
# chmod 0600、最后 mv（rename）替换目标，中途失败不会连旧 defaults.conf 一起弄丢。
# EXIT trap 负责清理残留临时文件。
tmp=$(mktemp /etc/sing-box/.defaults.conf.XXXXXX) || { echo '无法在 /etc/sing-box 创建临时文件，未修改默认配置。' >&2; exit 1; }
trap 'rm -f "$tmp"' EXIT
printf 'BACKEND_URL=%s\nSUBSCRIPTION_URL=%s\nTPROXY_TEMPLATE_URL=%s\nTUN_TEMPLATE_URL=%s\n' "$BACKEND_URL" "$SUBSCRIPTION_URL" "$TPROXY_TEMPLATE_URL" "$TUN_TEMPLATE_URL" > "$tmp"
# chown 失败不阻断（与仓库 install 兜底一致：vfat/extroot 上会失败，所有权不构成安全边界）；
# 权限必须落成 0600（凭据文件不能悄悄留在 0644），否则不提交。
chown root:root "$tmp" 2>/dev/null || true
commit_file "$tmp" "$DEFAULTS_FILE" 0600 || { echo '设置默认配置权限失败，未修改默认配置。' >&2; exit 1; }
echo '默认配置已更新。'
