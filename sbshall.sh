#!/bin/bash
set -Eeuo pipefail

# 兼容 Busybox 缺失 install 的环境
if ! command -v install >/dev/null 2>&1; then
    install() {
        local d=0 m='' o='' g=''
        while [ $# -gt 0 ]; do
            case "$1" in
                -d) d=1; shift ;;
                -m) m="$2"; shift 2 ;;
                -o) o="$2"; shift 2 ;;
                -g) g="$2"; shift 2 ;;
                -*) shift ;;
                *) break ;;
            esac
        done
        if [ "$d" -eq 1 ]; then
            mkdir -p "$@" || return 1
            [ -z "$m" ] || { chmod "$m" "$@" 2>/dev/null || return 1; }
        else
            [ $# -eq 2 ] || return 1
            # 先 rm 再写，避免覆盖正在运行脚本的 inode（写正在执行的脚本会 ETXTBSY 而失败）。
            rm -f "$2" 2>/dev/null || true
            cp -f "$1" "$2" || return 1
            [ -z "$m" ] || { chmod "$m" "$2" 2>/dev/null || return 1; }
            set -- "$2"
        fi
        [ -z "$o" ] || { chown "$o${g:+:$g}" "$@" 2>/dev/null || true; }
        return 0
    }
fi

# 修复点 1：允许外部传入环境变量，并强制 export 传递给子进程 menu.sh
export REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/meiao123/sbshell}"

github_api_download() {
    local path="$1" ref="$2" output="$3"
    # 静默尝试，避免 403 频次限制错误污染前台终端
    curl --fail --silent --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github.raw+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com/repos/meiao123/sbshell/contents/$path?ref=$ref" -o "$output" 2>/dev/null || return 1
    [ -s "$output" ] || { rm -f "$output"; return 1; }
}

github_archive_download() {
    local path="$1" ref="$2" output="$3" archive prefix entry
    command -v tar >/dev/null 2>&1 || return 1
    # 严格遵循 Busybox 规则：模板末尾必须为 XXXXXX
    archive=$(mktemp /tmp/sbshell-archive.XXXXXX) || return 1
    if ! curl --fail --silent --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 120 \
        "https://github.com/meiao123/sbshell/archive/$ref.tar.gz" -o "$archive" 2>/dev/null; then
        rm -f "$archive"
        return 1
    fi
    [ -s "$archive" ] || { rm -f "$archive"; return 1; }
    prefix=$(tar -tzf "$archive" 2>/dev/null | head -n1 | cut -d/ -f1)
    [ -n "$prefix" ] || { rm -f "$archive"; return 1; }
    entry="$prefix/$path"
    case "$entry" in
        *..*|/*) rm -f "$archive"; return 1 ;;
    esac
    tar -xOzf "$archive" "$entry" > "$output" 2>/dev/null || {
        rm -f "$output" "$archive"
        return 1
    }
    rm -f "$archive"
    [ -s "$output" ] || { rm -f "$output"; return 1; }
}

download_repo_file() {
    local path="$1" ref="$2" output="$3"
    # 第一层：直连 Raw
    if curl --fail --silent --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 60 "$REPO_RAW/$ref/$path" -o "$output" 2>/dev/null && [ -s "$output" ]; then
        return 0
    fi
    rm -f "$output"
    # 第二层：API 下载
    if github_api_download "$path" "$ref" "$output"; then
        return 0
    fi
    rm -f "$output"
    # 第三层：全量压缩包中提取
    github_archive_download "$path" "$ref" "$output"
}

SCRIPT_DIR=/etc/sing-box/scripts
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

[ "$(uname -s)" = Linux ] || { echo -e "${RED}当前系统不支持运行此脚本。${NC}" >&2; exit 1; }
[ -r /etc/os-release ] || { echo -e "${RED}无法识别操作系统。${NC}" >&2; exit 1; }

is_openwrt=false
if grep -qi openwrt /etc/os-release; then
    is_openwrt=true
    echo -e "${GREEN}系统为 OpenWrt。${NC}"
elif grep -Eqi 'debian|ubuntu|armbian' /etc/os-release; then
    echo -e "${GREEN}系统为 Debian/Ubuntu/Armbian。${NC}"
else
    echo -e "${RED}当前系统不是受支持的 Debian/Ubuntu/Armbian/OpenWrt。${NC}" >&2
    exit 1
fi

# 修复点 2：避免反复 opkg/apt update 拖垮路由器
# OpenWrt 25.12 起用 apk 取代了 opkg（ImmortalWrt 25.x 同源）：引导脚本必须能在
# 缺 curl/bash/nft 的新固件上把依赖装回来，只认 opkg 会停在第一步。
if command -v opkg >/dev/null 2>&1; then
    PKG_MGR=opkg
elif command -v apk >/dev/null 2>&1; then
    PKG_MGR=apk
else
    PKG_MGR=none
fi
PKG_UPDATED=false
install_package() {
    local package="$1"
    if ! $PKG_UPDATED; then
        if $is_openwrt; then
            case "$PKG_MGR" in
                opkg) opkg update ;;
                apk)  apk update ;;
                none) echo -e "${RED}未找到 opkg 或 apk 包管理器。${NC}" >&2; return 1 ;;
            esac
        else
            apt-get update
        fi
        PKG_UPDATED=true
    fi
    if $is_openwrt; then 
        case "$PKG_MGR" in
            opkg) opkg install "$package" ;;
            apk)  apk add "$package" ;;
            none) echo -e "${RED}未找到 opkg 或 apk 包管理器。${NC}" >&2; return 1 ;;
        esac
    else
        apt-get install -y "$package"
    fi
}

ensure_command() {
    local command="$1" package="$2"
    command -v "$command" >/dev/null 2>&1 || install_package "$package"
}

ensure_command curl curl
ensure_command bash bash
ensure_command nft nftables

command -v curl >/dev/null 2>&1 || { echo -e "${RED}curl 安装失败。${NC}" >&2; exit 1; }
command -v bash >/dev/null 2>&1 || { echo -e "${RED}bash 安装失败。${NC}" >&2; exit 1; }
command -v nft >/dev/null 2>&1 || { echo -e "${RED}nft 安装失败。${NC}" >&2; exit 1; }

install -d -o root -g root -m 0755 "$SCRIPT_DIR"

tmp=$(mktemp /tmp/sbshell-menu.XXXXXX)
trap 'rm -f "$tmp"' EXIT

if $is_openwrt; then
    download_repo_file "openwrt/menu.sh" "main" "$tmp"
else
    download_repo_file "debian/menu.sh" "main" "$tmp"
fi

[ -s "$tmp" ] || { echo -e "${RED}主脚本下载失败或为空。${NC}" >&2; exit 1; }
bash -n "$tmp"
install -o root -g root -m 0755 "$tmp" "$SCRIPT_DIR/menu.sh"

if $is_openwrt; then
    if [ -e /usr/bin/sb ] && [ ! -L /usr/bin/sb ]; then
        echo -e "${RED}/usr/bin/sb 已存在且不是符号链接，拒绝覆盖。${NC}" >&2
        exit 1
    fi
    ln -sfn "$SCRIPT_DIR/menu.sh" /usr/bin/sb
fi

echo -e "${GREEN}主脚本下载并校验完成（代码引用: main）。${NC}"
echo -e "${YELLOW}注意：脚本会修改系统网络、防火墙和 sing-box 配置，请确认已做好备份。${NC}"

rm -f "$tmp"
trap - EXIT

# 此时环境变量 REPO_RAW 已经 export，menu.sh 可以直接读取
exec bash "$SCRIPT_DIR/menu.sh" "$@"
