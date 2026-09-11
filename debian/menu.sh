#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
WHITE='\033[1;37m'
BOLD='\033[1m'
LIGHT_PURPLE='\033[1;35m'
LIGHT_BLUE='\033[1;34m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

SCRIPT_DIR="/etc/sing-box/scripts"
INITIALIZED_FILE="$SCRIPT_DIR/.initialized"
ROLE_FILE="$SCRIPT_DIR/.role"
BASE_URL="https://raw.githubusercontent.com/meiao123/sbshell/main/debian"
ROLE=""

SCRIPTS=(
    "menu.sh" "install_singbox.sh" "check_update.sh" "update_scripts.sh" "update_ui.sh"
    "manual_input.sh" "manual_update.sh" "auto_update.sh" "switch_mode.sh" "configure_tproxy.sh" "configure_tun.sh"
    "update_config.sh" "setup.sh" "ufw.sh"
    "start_singbox.sh" "stop_singbox.sh" "manage_autostart.sh" "check_config.sh"
    "check_environment.sh" "set_network.sh" "clean_nft.sh" "kernel.sh" "optimize.sh" "set_defaults.sh" "delaytest.sh" "commands.sh"
)

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo -e "${RED}缺少依赖: $1${NC}" >&2
        return 1
    }
}

run_script() {
    local message="$1" script_name="$2" quiet_mode="${3:-}"
    echo -e "${CYAN}${message}...${NC}"
    if [[ "$quiet_mode" == "--quiet" ]]; then
        if bash "$SCRIPT_DIR/$script_name" >/dev/null; then
            echo -e "${GREEN}${message}成功。${NC}"
        else
            echo -e "${RED}${message}失败！${NC}"
            return 1
        fi
    else
        if bash "$SCRIPT_DIR/$script_name"; then
            return 0
        else
            echo -e "${RED}${message}失败！${NC}"
            return 1
        fi
    fi
}

run_systemctl() {
    local message="$1" action="$2"
    echo -e "${CYAN}${message}...${NC}"
    if systemctl "$action" sing-box >/dev/null 2>&1; then
        echo -e "${GREEN}${message}成功。${NC}"
    else
        echo -e "${RED}${message}失败！${NC}"
        return 1
    fi
}

download_script() {
    local script="$1" tmp
    tmp=$(mktemp "/tmp/sbshell.${script//\//_}.XXXXXX")
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
        "$BASE_URL/$script" -o "$tmp"; then
        rm -f "$tmp"
        echo -e "${YELLOW}下载 $script 失败。${NC}" >&2
        return 1
    fi
    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        echo -e "${RED}$script 语法校验失败，拒绝安装。${NC}" >&2
        return 1
    fi
    install -o root -g root -m 0755 "$tmp" "$SCRIPT_DIR/$script"
    rm -f "$tmp"
}

parallel_download_scripts() {
    local tmpdir pid failed=0 script
    tmpdir=$(mktemp -d /tmp/sbshell-download.XXXXXX)
    for script in "${SCRIPTS[@]}"; do
        (
            local tmp="$tmpdir/${script//\//_}"
            if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
                "$BASE_URL/$script" -o "$tmp" && bash -n "$tmp"; then
                install -o root -g root -m 0755 "$tmp" "$SCRIPT_DIR/$script"
            else
                echo "$script" >> "$tmpdir/failed"
                exit 1
            fi
        ) &
    done
    for pid in $(jobs -pr); do
        wait "$pid" || failed=1
    done
    if [ "$failed" -ne 0 ] || [ -f "$tmpdir/failed" ]; then
        echo -e "${RED}一个或多个脚本下载/校验失败，未完成更新。${NC}" >&2
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"
    echo -e "${GREEN}所有脚本下载并校验完成。${NC}"
}

check_and_download_scripts() {
    local script
    for script in "${SCRIPTS[@]}"; do
        if [ ! -s "$SCRIPT_DIR/$script" ]; then
            echo -e "${YELLOW}发现缺失脚本: $script${NC}"
            download_script "$script" || return 1
        fi
    done
}

prepare_scripts() {
    echo -e "${CYAN}正在更新管理脚本...${NC}"
    find "$SCRIPT_DIR" -type f -name '*.sh' ! -name 'menu.sh' -delete
    rm -f "$INITIALIZED_FILE"
    parallel_download_scripts
}

client_initialize() {
    prepare_scripts || return 1
    run_script "检查系统环境" "check_environment.sh" --quiet || return 1
    run_script "安装/更新 sing-box" "install_singbox.sh" --quiet || return 1
    run_script "配置代理模式" "switch_mode.sh" || return 1
    run_script "配置订阅链接" "manual_input.sh" || return 1
    run_script "启动 sing-box" "start_singbox.sh" --quiet || return 1
    echo -e "${GREEN}--- 客户端初始化完成 ---${NC}"
}

server_initialize() {
    prepare_scripts || return 1
    run_script "配置防火墙" "ufw.sh" || return 1
    run_script "安装/更新 sing-box" "install_singbox.sh" --quiet || return 1
    run_script "更新服务端配置" "update_config.sh" || return 1
    run_systemctl "启动 sing-box 服务" "start" || return 1
    echo -e "${GREEN}--- 服务端初始化完成 ---${NC}"
}

select_role() {
    local role_choice
    echo -e "${CYAN}请选择运行角色: [1] 客户端 [2] 服务端${NC}"
    read -rp "输入数字选择: " role_choice
    case "$role_choice" in
        1) ROLE="client" ;;
        2) ROLE="server" ;;
        *) echo -e "${YELLOW}无效选择，默认为客户端。${NC}"; ROLE="client" ;;
    esac
    printf '%s\n' "$ROLE" > "$ROLE_FILE"
    chmod 0644 "$ROLE_FILE"
}

run_initialization() {
    select_role
    echo -e "${YELLOW}为 '$ROLE' 角色进行首次初始化。${NC}"
    read -rp "按回车开始，或输入 'skip' 仅下载脚本进入菜单: " init_choice
    if [[ "$init_choice" =~ ^[Ss]kip$ ]]; then
        parallel_download_scripts || return 1
    elif [ "$ROLE" = "server" ]; then
        server_initialize || return 1
    else
        client_initialize || return 1
    fi
    touch "$INITIALIZED_FILE"
    chmod 0644 "$INITIALIZED_FILE"
}

setup_alias() {
    local bashrc="${HOME:-/root}/.bashrc"
    if ! grep -Fq 'alias sb=' "$bashrc" 2>/dev/null; then
        printf '\n# sing-box 快捷方式\nalias sb='"'bash /etc/sing-box/scripts/menu.sh'"'\n' >> "$bashrc"
    fi
    install -o root -g root -m 0755 /dev/stdin /usr/local/bin/sb <<'EOF'
#!/bin/bash
exec sudo bash /etc/sing-box/scripts/menu.sh "$@"
EOF
}

show_client_menu() {
    echo -e "\n${CYAN}================= sbshell客户端管理菜单 =================${NC}"
    echo -e "${BOLD}${LIGHT_BLUE}--- 配置管理 ---${NC}"
    echo -e "${LIGHT_BLUE} 1. 模式切换与配置${NC}"
    echo -e "${LIGHT_BLUE} 2. 手动更新配置${NC}"
    echo -e "${LIGHT_BLUE} 3. 自动更新配置${NC}"
    echo -e "${LIGHT_BLUE} 4. 设置默认参数${NC}"
    echo -e "${BOLD}${LIGHT_PURPLE}--- 服务控制 ---${NC}"
    echo -e "${LIGHT_PURPLE} 5. 启动sing-box${NC}"
    echo -e "${LIGHT_PURPLE} 6. 停止sing-box${NC}"
    echo -e "${LIGHT_PURPLE} 7. 管理自启动${NC}"
    echo -e "${BOLD}${YELLOW}--- 更新与维护 ---${NC}"
    echo -e "${YELLOW} 8. 更新sing-box${NC}"
    echo -e "${YELLOW} 9. 更新脚本${NC}"
    echo -e "${YELLOW}10. 更新面板${NC}"
    echo -e "${BOLD}${WHITE}--- 系统与网络 ---${NC}"
    echo -e "${WHITE}11. 网络设置${NC}"
    echo -e "${WHITE}12. 常用命令${NC}"
    echo -e "${WHITE}13. 更换XanMod内核${NC}"
    echo -e "${WHITE}14. 网络优化${NC}"
    echo -e "${CYAN}----------------------------------------------------${NC}"
    echo -e "${GREEN} 0. 退出${NC}"
    echo -e "${CYAN}====================================================${NC}"
}

handle_client_choice() {
    local choice
    read -rp "请选择操作: " choice
    case "$choice" in
        1) run_script "配置代理模式" "switch_mode.sh" && run_script "配置订阅链接" "manual_input.sh" && run_script "启动 sing-box" "start_singbox.sh" --quiet ;;
        2) run_script "手动更新配置" "manual_update.sh" ;;
        3) run_script "自动更新配置" "auto_update.sh" ;;
        4) run_script "设置默认参数" "set_defaults.sh" ;;
        5) run_script "启动sing-box" "start_singbox.sh" --quiet ;;
        6) run_script "停止sing-box" "stop_singbox.sh" --quiet ;;
        7) run_script "管理自启动" "manage_autostart.sh" ;;
        8) if command -v sing-box >/dev/null 2>&1; then run_script "检查 sing-box 更新" "check_update.sh"; else run_script "安装/更新 sing-box" "install_singbox.sh"; fi ;;
        9) run_script "更新所有脚本" "update_scripts.sh" ;;
        10) run_script "更新控制面板" "update_ui.sh" ;;
        11) run_script "网络设置" "set_network.sh" ;;
        12) run_script "常用命令" "commands.sh" ;;
        13) run_script "更换XanMod内核" "kernel.sh" ;;
        14) run_script "网络优化" "optimize.sh" ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效的选择${NC}" ;;
    esac
}

show_server_menu() {
    echo -e "\n${CYAN}================= sbshell服务端管理菜单 =================${NC}"
    echo -e "${BOLD}${LIGHT_PURPLE}--- 服务控制 ---${NC}"
    echo -e "${LIGHT_PURPLE} 1. 启动sing-box${NC}"
    echo -e "${LIGHT_PURPLE} 2. 停止sing-box${NC}"
    echo -e "${LIGHT_PURPLE} 3. 重启sing-box${NC}"
    echo -e "${LIGHT_PURPLE} 4. 设为自启${NC}"
    echo -e "${LIGHT_PURPLE} 5. 查看日志${NC}"
    echo -e "${BOLD}${YELLOW}--- 配置与更新 ---${NC}"
    echo -e "${YELLOW} 6. 更新配置文件${NC}"
    echo -e "${YELLOW} 7. 更新sing-box${NC}"
    echo -e "${YELLOW} 8. 更新脚本${NC}"
    echo -e "${YELLOW} 9. 证书申请${NC}"
    echo -e "${BOLD}${WHITE}--- 系统与网络 ---${NC}"
    echo -e "${WHITE}10. 更换XanMod内核${NC}"
    echo -e "${WHITE}11. 网络优化${NC}"
    echo -e "${WHITE}12. 手动配置防火墙${NC}"
    echo -e "${CYAN}----------------------------------------------------${NC}"
    echo -e "${GREEN} 0. 退出${NC}"
    echo -e "${CYAN}====================================================${NC}"
}

handle_server_choice() {
    local choice
    read -rp "请选择操作: " choice
    case "$choice" in
        1) run_systemctl "启动sing-box" "start" ;;
        2) run_systemctl "停止sing-box" "stop" ;;
        3) run_systemctl "重启sing-box" "restart" ;;
        4) run_systemctl "设置开机自启" "enable" ;;
        5) journalctl -u sing-box --output cat -f ;;
        6) run_script "更新服务端配置文件" "update_config.sh" ;;
        7) if command -v sing-box >/dev/null 2>&1; then run_script "检查 sing-box 更新" "check_update.sh"; else run_script "安装/更新 sing-box" "install_singbox.sh"; fi ;;
        8) run_script "更新脚本" "update_scripts.sh" ;;
        9) run_script "证书申请" "setup.sh" ;;
        10) run_script "更换XanMod内核" "kernel.sh" ;;
        11) run_script "网络优化" "optimize.sh" ;;
        12) run_script "手动配置防火墙" "ufw.sh" ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效的选择${NC}" ;;
    esac
}

main() {
    require_cmd curl
    mkdir -p "$SCRIPT_DIR"
    chown root:root "$SCRIPT_DIR"
    chmod 0755 "$SCRIPT_DIR"
    cd "$SCRIPT_DIR"

    if [[ "${1:-}" == "menu" ]]; then shift; fi

    if [ ! -f "$INITIALIZED_FILE" ]; then
        run_initialization || exit 1
    else
        if [ -f "$ROLE_FILE" ]; then
            ROLE=$(cat "$ROLE_FILE")
        else
            rm -f "$INITIALIZED_FILE"
            run_initialization || exit 1
        fi
        check_and_download_scripts || exit 1
    fi

    case "$ROLE" in
        client)
            setup_alias
            while true; do show_client_menu; handle_client_choice; done
            ;;
        server)
            setup_alias
            while true; do show_server_menu; handle_server_choice; done
            ;;
        *) echo -e "${RED}角色无效: $ROLE${NC}" >&2; exit 1 ;;
    esac
}

main "$@"
