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

# 固定更新版本：先解析 main 当前 commit，再让本次更新全部绑定到该 commit。
export REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/meiao123/sbshell}"
MAIN_REF="main"
GITHUB_API_BASE="https://api.github.com/repos/meiao123/sbshell"
resolve_main_commit() {
    local endpoint response_file err_file curl_args main_sha

    case "${SBSHELL_PINNED_COMMIT:-}" in
        ''|*[!0-9a-fA-F]*) ;;
        *)
            if [ "${#SBSHELL_PINNED_COMMIT}" -eq 40 ]; then
                printf '%s\n' "$SBSHELL_PINNED_COMMIT"
                unset SBSHELL_PINNED_COMMIT
                return 0
            fi
            ;;
    esac

    response_file=$(mktemp /tmp/sbshell-main-ref.XXXXXX) || return 1
    err_file="${response_file}.err"

    # 第一优先：Commits API，返回顶层 sha，避免依赖嵌套 ref 结构。
    for curl_args in '' '-4'; do
        endpoint="$GITHUB_API_BASE/commits/$MAIN_REF"
        rm -f "$response_file" "$err_file"
        if curl $curl_args --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 8 --max-time 20 \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "$endpoint" -o "$response_file" 2>"$err_file"; then
            main_sha=$(grep -m1 -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{40}"' "$response_file" 2>/dev/null | sed -n 's/.*"\([0-9a-fA-F]\{40\}\)".*/\1/p')
            if [ -n "$main_sha" ] && [ "${#main_sha}" -eq 40 ]; then
                rm -f "$response_file" "$err_file"
                printf '%s\n' "$main_sha"
                return 0
            fi
        fi
    done

    # 第二优先：Git Ref API，兼容旧版/不同 API 响应。
    for curl_args in '' '-4'; do
        endpoint="$GITHUB_API_BASE/git/ref/heads/$MAIN_REF"
        rm -f "$response_file" "$err_file"
        if curl $curl_args --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --connect-timeout 8 --max-time 20 \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "$endpoint" -o "$response_file" 2>"$err_file"; then
            main_sha=$(grep -m1 -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{40}"' "$response_file" 2>/dev/null | sed -n 's/.*"\([0-9a-fA-F]\{40\}\)".*/\1/p')
            if [ -n "$main_sha" ] && [ "${#main_sha}" -eq 40 ]; then
                rm -f "$response_file" "$err_file"
                printf '%s\n' "$main_sha"
                return 0
            fi
        fi
    done

echo "获取 main commit SHA 失败：无法访问 GitHub API（api.github.com）。" >&2
if [ -s "$err_file" ]; then
    echo "API 请求错误：$(tr '\n' ' ' < "$err_file" | sed 's/[[:space:]]\+/ /g' | cut -c1-240)" >&2
fi
rm -f "$response_file" "$err_file"
return 1
}
github_api_download() {
    local path="$1" ref="$2" output="$3"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github.raw+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
        "$GITHUB_API_BASE/contents/$path?ref=$ref" -o "$output" || return 1
    [ -s "$output" ] || { rm -f "$output"; return 1; }
}
github_archive_download() {
    local path="$1" ref="$2" output="$3" archive prefix entry
    command -v tar >/dev/null 2>&1 || return 1
    archive=$(mktemp /tmp/sbshell-archive.XXXXXX) || return 1
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 \
        "https://github.com/meiao123/sbshell/archive/$ref.tar.gz" -o "$archive"; then
        rm -f "$archive"; return 1
    fi
    [ -s "$archive" ] || { rm -f "$archive"; return 1; }
    list=$(mktemp /tmp/sbshell-archive-list.XXXXXX) || { rm -f "$archive"; return 1; }
    if ! tar -tzf "$archive" > "$list" 2>/dev/null; then rm -f "$archive" "$list"; return 1; fi
    first=$(head -n1 "$list") || true; prefix=${first%%/*}; rm -f "$list"
    [ -n "$prefix" ] || { rm -f "$archive"; return 1; }
    entry="$prefix/$path"
    case "$entry" in *..*|/*) rm -f "$archive"; return 1;; esac
    tar -xOzf "$archive" "$entry" > "$output" 2>/dev/null || { rm -f "$output" "$archive"; return 1; }
    rm -f "$archive"; [ -s "$output" ] || { rm -f "$output"; return 1; }
}
download_repo_file() {
    local path="$1" ref="$2" output="$3" transport="$4"
    case "$transport" in
        raw)
            if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
                "$REPO_RAW/$ref/$path" -o "$output" 2>/dev/null; then
                if [ -s "$output" ]; then return 0; fi
            fi ;;
        api) github_api_download "$path" "$ref" "$output"; return $? ;;
        archive) github_archive_download "$path" "$ref" "$output"; return $? ;;
        *) return 2 ;;
    esac
    rm -f "$output"; return 1
}

verify_manifest_entry() {
    local manifest="$1" manifest_name="$2" file="$3" hash actual
    [ -f "$manifest" ] || { echo '未找到 SHA256SUMS，拒绝安装（无法校验下载内容）。' >&2; return 1; }
    if ! command -v sha256sum >/dev/null 2>&1; then
        echo '未找到 sha256sum，本次跳过下载内容校验（建议使用带 sha256sum 的 busybox 或安装 coreutils-sha256sum）。' >&2
        return 0
    fi
    hash=$(awk -v target="$manifest_name" '$2 == target { print $1; exit }' "$manifest")
    [ -n "$hash" ] || { echo "SHA256SUMS 中没有 $manifest_name 的条目。" >&2; return 1; }
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    [ -n "$actual" ] || { echo "完整性校验失败：$manifest_name 未下载成功。" >&2; return 1; }
    [ "$actual" = "$hash" ] || { echo "完整性校验失败：$manifest_name 与 SHA256SUMS 不符（期望 $hash，实际 $actual）。" >&2; return 1; }
    return 0
}

download_bootstrap_menu() {
    local commit="$1" menu_output="$2" manifest_output="$3" transport
    for transport in raw api archive; do
        rm -f "$menu_output" "$manifest_output"
        if download_repo_file "openwrt/menu.sh" "$commit" "$menu_output" "$transport" &&
            download_repo_file "SHA256SUMS" "$commit" "$manifest_output" "$transport" &&
            verify_manifest_entry "$manifest_output" "openwrt/menu.sh" "$menu_output"; then return 0; fi
        case "$transport" in
            raw) echo -e "${YELLOW}Raw 下载内容校验失败或不可用，切换 GitHub Contents API。${NC}" >&2 ;;
            api) echo -e "${YELLOW}GitHub Contents API 下载内容校验失败或不可用，切换 commit archive。${NC}" >&2 ;;
            archive) echo -e "${RED}GitHub commit archive 下载内容校验仍然失败。${NC}" >&2 ;;
        esac
    done
    return 1
}

SCRIPT_DIR=/etc/sing-box/scripts
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

[ "$(uname -s)" = Linux ] || { echo -e "${RED}当前系统不支持运行此脚本。${NC}" >&2; exit 1; }
[ -r /etc/os-release ] || { echo -e "${RED}无法识别操作系统。${NC}" >&2; exit 1; }

# 本仓库只支持 OpenWrt / ImmortalWrt：Debian/Ubuntu/Armbian 分支及其 apt 路径已移除。
if grep -qiE 'openwrt|immortalwrt' /etc/os-release; then
    echo -e "${GREEN}系统为 OpenWrt。${NC}"
else
    echo -e "${RED}本脚本仅支持 OpenWrt / ImmortalWrt（当前系统不受支持）。${NC}" >&2
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
        case "$PKG_MGR" in
            opkg) opkg update ;;
            apk)  apk update ;;
            none) echo -e "${RED}未找到 opkg 或 apk 包管理器。${NC}" >&2; return 1 ;;
        esac
        PKG_UPDATED=true
    fi
    case "$PKG_MGR" in
        opkg) opkg install "$package" ;;
        apk)  apk add "$package" ;;
        none) echo -e "${RED}未找到 opkg 或 apk 包管理器。${NC}" >&2; return 1 ;;
    esac
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

bootstrap_tmp=$(mktemp -d /tmp/sbshell-bootstrap.XXXXXX) || { echo -e "${RED}无法创建主脚本临时目录。${NC}" >&2; exit 1; }
trap 'rm -rf "$bootstrap_tmp"' EXIT
commit=$(resolve_main_commit) || { echo -e "${RED}无法获取 main 当前 commit SHA，已中止更新（无法安全固定版本）。${NC}" >&2; exit 1; }
echo -e "${CYAN}本次更新已固定到 main commit: $commit${NC}"
if ! download_bootstrap_menu "$commit" "$bootstrap_tmp/menu.sh" "$bootstrap_tmp/SHA256SUMS"; then
    echo -e "${RED}主脚本下载或完整性校验失败，已中止更新。${NC}" >&2; exit 1
fi
bash -n "$bootstrap_tmp/menu.sh"
install -o root -g root -m 0755 "$bootstrap_tmp/menu.sh" "$SCRIPT_DIR/menu.sh"

if [ -e /usr/bin/sb ] && [ ! -L /usr/bin/sb ]; then
    echo -e "${RED}/usr/bin/sb 已存在且不是符号链接，拒绝覆盖。${NC}" >&2
    exit 1
fi
ln -sfn "$SCRIPT_DIR/menu.sh" /usr/bin/sb

export SBSHELL_PINNED_COMMIT="$commit"
echo -e "${GREEN}主脚本下载并校验完成（代码引用: main@$commit）。${NC}"
echo -e "${YELLOW}注意：脚本会修改系统网络、防火墙和 sing-box 配置，请确认已做好备份。${NC}"

rm -f "$tmp"
trap - EXIT

# 此时环境变量 REPO_RAW 已经 export，menu.sh 可以直接读取
exec bash "$SCRIPT_DIR/menu.sh" "$@"
