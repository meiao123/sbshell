#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'
TMP_DIR=$(mktemp -d /tmp/sbshell-package.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"
command -v apt-get >/dev/null 2>&1 || { echo -e "${RED}仅支持 Debian/Ubuntu。${NC}" >&2; exit 1; }
command -v dpkg >/dev/null 2>&1 || { echo -e "${RED}缺少 dpkg。${NC}" >&2; exit 1; }

echo "正在检测sing-box最新版本..."
apt-get update -qq > /dev/null 2>&1

if command -v sing-box &> /dev/null; then
    current_version=$(sing-box version | awk '/sing-box version/ {print $3; exit}')
    echo -e "${CYAN}当前安装的sing-box版本为:${NC} $current_version"

    stable_version=$(apt-cache policy sing-box | awk '/Candidate:/ {print $2; exit}')
    beta_version=$(apt-cache policy sing-box-beta | awk '/Candidate:/ {print $2; exit}')

    echo -e "${CYAN}稳定版最新版本：${NC} ${stable_version:-未知}"
    echo -e "${CYAN}测试版最新版本：${NC} ${beta_version:-未知}"

    while true; do
        read -rp "是否切换版本(1: 稳定版, 2: 测试版） (当前版本: $current_version, 回车取消操作): " switch_choice
        case "$switch_choice" in
            1)
                pkg='sing-box'
                echo "下载稳定版..."
                apt-get download "${pkg}"
                mapfile -t debs < <(find "$PWD" -maxdepth 1 -type f -name "${pkg}_*.deb" -print)
                [ "${#debs[@]}" -eq 1 ] || { echo -e "${RED}未找到唯一的稳定版 deb 包。${NC}" >&2; exit 1; }
                install -m 0644 "${debs[0]}" "$TMP_DIR/package.deb"
                sudo apt-get remove --auto-remove sing-box-beta -y
                sudo dpkg -i "$TMP_DIR/package.deb"
                rm -f -- "${debs[0]}"
                break
                ;;
            2)
                pkg='sing-box-beta'
                echo "下载测试版..."
                apt-get download "${pkg}"
                mapfile -t debs < <(find "$PWD" -maxdepth 1 -type f -name "${pkg}_*.deb" -print)
                [ "${#debs[@]}" -eq 1 ] || { echo -e "${RED}未找到唯一的测试版 deb 包。${NC}" >&2; exit 1; }
                install -m 0644 "${debs[0]}" "$TMP_DIR/package.deb"
                sudo apt-get remove --auto-remove sing-box -y
                sudo dpkg -i "$TMP_DIR/package.deb"
                rm -f -- "${debs[0]}"
                break
                ;;
            '')
                echo "不进行版本切换"
                break
                ;;
            *)
                echo -e "${RED}无效的选择，请输入 1 或 2。${NC}"
                ;;
        esac
    done
else
    echo -e "${RED}sing-box 未安装${NC}"
fi
