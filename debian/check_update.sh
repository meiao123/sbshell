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

apt-get update -qq >/dev/null 2>&1
if ! command -v sing-box >/dev/null 2>&1; then
    echo -e "${RED}sing-box 未安装${NC}"
    exit 0
fi
current_version=$(sing-box version | awk '/sing-box version/ {print $3; exit}')
stable_version=$(apt-cache policy sing-box | awk '/Candidate:/ {print $2; exit}')
beta_version=$(apt-cache policy sing-box-beta | awk '/Candidate:/ {print $2; exit}')
echo -e "${CYAN}当前安装的 sing-box 版本: ${NC}$current_version"
echo -e "${CYAN}稳定版最新版本: ${NC}${stable_version:-未知}"
echo -e "${CYAN}测试版最新版本: ${NC}${beta_version:-未知}"

while true; do
    read -rp "是否切换版本(1: 稳定版, 2: 测试版, 回车取消): " choice
    case "$choice" in
        1|2)
            pkg=sing-box
            [ "$choice" = 2 ] && pkg=sing-box-beta
            (
                cd "$TMP_DIR"
                apt-get download "$pkg"
            )
            mapfile -t debs < <(find "$TMP_DIR" -type f -name "${pkg}_*.deb" -print)
            [ "${#debs[@]}" -eq 1 ] || { echo -e "${RED}未找到唯一的 $pkg deb 包。${NC}" >&2; exit 1; }
            if ! apt-get install -y "${debs[0]}"; then
                echo -e "${RED}安装 $pkg 失败，未主动删除当前版本。${NC}" >&2
                exit 1
            fi
            rm -f -- "${debs[0]}"
            break
            ;;
        '')
            echo '不进行版本切换'
            break
            ;;
        *)
            echo -e "${RED}无效的选择。${NC}"
            ;;
    esac
done
