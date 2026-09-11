#!/bin/bash
set -Eeuo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; WHITE='\033[1;37m'; BOLD='\033[1m'; LIGHT_PURPLE='\033[1;35m'; LIGHT_BLUE='\033[1;34m'; NC='\033[0m'
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

SCRIPT_DIR=/etc/sing-box/scripts
INITIALIZED_FILE=/etc/sing-box/.initialized
ROLE_FILE=/etc/sing-box/.role
BASE_REF=91865d43c91b5d22141d412c27d3c54624c4be95
BASE_URL="https://raw.githubusercontent.com/meiao123/sbshell/$BASE_REF/debian"
ROLE=''
SCRIPTS=(
  menu.sh install_singbox.sh check_update.sh update_scripts.sh update_ui.sh manual_input.sh manual_update.sh auto_update.sh
  switch_mode.sh configure_tproxy.sh configure_tun.sh update_config.sh setup.sh ufw.sh start_singbox.sh stop_singbox.sh
  manage_autostart.sh check_config.sh check_environment.sh set_network.sh clean_nft.sh kernel.sh optimize.sh
  delaytest.sh commands.sh gen_server_config.sh set_defaults.sh
)

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo -e "${RED}缺少依赖: $1${NC}" >&2; return 1; }; }
run_script() {
    local message="$1" script_name="$2" quiet="${3:-}"
    echo -e "${CYAN}${message}...${NC}"
    if [[ "$quiet" == --quiet ]]; then
        bash "$SCRIPT_DIR/$script_name" >/dev/null
    else
        bash "$SCRIPT_DIR/$script_name"
    fi
}
run_systemctl() {
    local message="$1" action="$2"
    echo -e "${CYAN}${message}...${NC}"
    systemctl "$action" sing-box >/dev/null 2>&1 || { echo -e "${RED}${message}失败。${NC}"; return 1; }
    echo -e "${GREEN}${message}成功。${NC}"
}
confirm_yes() {
    local prompt="$1" answer
    while true; do
        # stdin 到 EOF（Ctrl-D 或非 tty）时 read 返回非 0；本函数总是被 `||` 调用，
        # 函数体内 errexit 失效 —— 不处理的话空答案会不断命中 `*)` 分支，
        # 变成 100% CPU 的死循环（实测 2 秒输出 13 万行）。
        if ! read -r -p "$prompt [y/n]: " answer; then
            echo -e "${YELLOW}无法读取输入（EOF），已取消。${NC}" >&2
            return 1
        fi
        case "$answer" in
            [Yy]) return 0;;
            [Nn]) return 1;;
            *) echo -e "${YELLOW}请输入 y 或 n。${NC}";;
        esac
    done
}
uninstall_sbshell() {
    echo -e "${YELLOW}此操作仅卸载 Sbshell 管理脚本及其快捷方式。${NC}"
    echo -e "${YELLOW}不会删除 sing-box 程序、配置文件、systemd 服务或现有代理配置。${NC}"
    confirm_yes '第一次确认：确定要卸载 Sbshell 吗？' || { echo -e "${GREEN}已取消卸载。${NC}"; return 0; }
    confirm_yes '第二次确认：此操作将删除 Sbshell 管理脚本，确定继续吗？' || { echo -e "${GREEN}已取消卸载。${NC}"; return 0; }
    echo -e "${CYAN}正在卸载 Sbshell...${NC}"
    rm -f /usr/local/bin/sb /etc/cron.d/sbshell-ui /etc/cron.d/sbshell-singbox /etc/sing-box/update-ui.sh /etc/sing-box/update-singbox.sh "$INITIALIZED_FILE" "$ROLE_FILE"
    if [ -f /etc/sing-box/scripts/menu.sh ]; then
        sed -i '/# sing-box 快捷方式/,/alias sb=/d' /root/.bashrc 2>/dev/null || true
    fi
    rm -rf "$SCRIPT_DIR"
    echo -e "${GREEN}Sbshell 已卸载。sing-box 及其现有配置已保留。${NC}"
    exit 0
}
download_all_scripts() {
    local tmpdir backupdir script item rc=0
    # 两个 mktemp 都必须检查：本函数总在 `||` 上下文里被调用，errexit 失效，
    # 空变量会让 `"$tmpdir/$script"` 折叠成 /脚本名（写到文件系统根目录）。
    tmpdir=$(mktemp -d /tmp/sbshell-download.XXXXXX) || return 1
    backupdir=$(mktemp -d /tmp/sbshell-backup.XXXXXX) || { rm -rf "$tmpdir"; return 1; }
    # 只回滚“确实备份成功”的脚本：备份失败与“原本不存在”必须区分，
    # 否则备份目录写满时 cp 失败 + 后续 install 失败会把健康脚本直接删掉。
    backed_up=()
    restore_scripts() {
        local item
        for item in "${backed_up[@]}"; do
            install -o root -g root -m 0755 "$backupdir/$item" "$SCRIPT_DIR/$item" || true
        done
    }
    for script in "${SCRIPTS[@]}"; do
        if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 "$BASE_URL/$script" -o "$tmpdir/$script" ||
            [ ! -s "$tmpdir/$script" ] ||
            ! bash -n "$tmpdir/$script"; then
            rc=1
            break
        fi
        if head -n1 "$tmpdir/$script" | grep -q '^#!/bin/sh' && ! sh -n "$tmpdir/$script"; then
            rc=1
            break
        fi
    done
    if [ "$rc" -eq 0 ]; then
        for script in "${SCRIPTS[@]}"; do
            if [ -f "$SCRIPT_DIR/$script" ]; then
                if ! cp -a "$SCRIPT_DIR/$script" "$backupdir/$script"; then
                    echo -e "${RED}备份 $script 失败，已中止更新（现有安装保持不变）。${NC}" >&2
                    rc=1
                    break
                fi
                backed_up+=("$script")
            fi
        done
    fi
    if [ "$rc" -eq 0 ]; then
        for script in "${SCRIPTS[@]}"; do
            if ! install -o root -g root -m 0755 "$tmpdir/$script" "$SCRIPT_DIR/$script"; then
                restore_scripts
                rc=1
                break
            fi
        done
    fi
    rm -rf "$tmpdir" "$backupdir"
    return "$rc"
}
check_and_download_scripts() {
    local script
    for script in "${SCRIPTS[@]}"; do
        if [ ! -s "$SCRIPT_DIR/$script" ]; then
            echo -e "${YELLOW}发现缺失脚本: $script${NC}"
            download_all_scripts || return 1
            return 0
        fi
    done
}
prepare_scripts() { echo -e "${CYAN}正在更新管理脚本...${NC}"; download_all_scripts || { echo -e "${RED}脚本更新失败，保留现有安装。${NC}" >&2; return 1; }; }
client_initialize() { prepare_scripts || return 1; run_script '检查系统环境' check_environment.sh || return 1; run_script '安装/更新 sing-box' install_singbox.sh || return 1; run_script '配置代理模式' switch_mode.sh || return 1; run_script '配置订阅链接' manual_input.sh || return 1; run_script '启动 sing-box' start_singbox.sh || return 1; echo -e "${GREEN}--- 客户端初始化完成 ---${NC}"; }
server_initialize() { prepare_scripts || return 1; run_script '配置防火墙' ufw.sh || return 1; run_script '安装/更新 sing-box' install_singbox.sh || return 1; run_script '更新服务端配置' update_config.sh || return 1; run_systemctl '启动 sing-box 服务' start || return 1; echo -e "${GREEN}--- 服务端初始化完成 ---${NC}"; }
select_role() { local role_choice; echo -e "${CYAN}请选择运行角色: [1] 客户端 [2] 服务端${NC}"; read -rp '输入数字选择: ' role_choice; case "$role_choice" in 1) ROLE=client;; 2) ROLE=server;; *) ROLE=client; echo -e "${YELLOW}无效选择，默认客户端。${NC}";; esac; printf '%s\n' "$ROLE" > "$ROLE_FILE"; chmod 0644 "$ROLE_FILE"; }
run_initialization() {
    select_role
    echo -e "${YELLOW}为 '$ROLE' 角色进行首次初始化。${NC}"
    read -rp "按回车开始，或输入 'skip' 仅下载脚本进入菜单: " init_choice
    if [[ "$init_choice" =~ ^[Ss]kip$ ]]; then
        download_all_scripts || return 1
    elif [ "$ROLE" = server ]; then
        server_initialize || return 1
    else
        client_initialize || return 1
    fi
    touch "$INITIALIZED_FILE"
    chmod 0644 "$INITIALIZED_FILE"
}
setup_alias() { local bashrc=/root/.bashrc; if ! grep -Fq 'alias sb=' "$bashrc" 2>/dev/null; then printf '\n# sing-box 快捷方式\nalias sb='"'bash /etc/sing-box/scripts/menu.sh'"'\n' >> "$bashrc"; fi; cat > /usr/local/bin/sb <<'EOF'
#!/bin/bash
exec sudo bash /etc/sing-box/scripts/menu.sh "$@"
EOF
chown root:root /usr/local/bin/sb; chmod 0755 /usr/local/bin/sb; }
show_client_menu() { echo -e "\n${CYAN}================= sbshell客户端管理菜单 =================${NC}"; echo -e "${BOLD}${LIGHT_BLUE}--- 配置管理 ---${NC}"; echo -e "${LIGHT_BLUE} 1. 模式切换与配置${NC}"; echo -e "${LIGHT_BLUE} 2. 手动更新配置${NC}"; echo -e "${LIGHT_BLUE} 3. 自动更新配置${NC}"; echo -e "${LIGHT_BLUE} 4. 设置默认参数${NC}"; echo -e "${BOLD}${LIGHT_PURPLE}--- 服务控制 ---${NC}"; echo -e "${LIGHT_PURPLE} 5. 启动sing-box${NC}"; echo -e "${LIGHT_PURPLE} 6. 停止sing-box${NC}"; echo -e "${LIGHT_PURPLE} 7. 管理自启动${NC}"; echo -e "${BOLD}${YELLOW}--- 更新与维护 ---${NC}"; echo -e "${YELLOW} 8. 更新sing-box${NC}"; echo -e "${YELLOW} 9. 更新脚本${NC}"; echo -e "${YELLOW}10. 更新面板${NC}"; echo -e "${BOLD}${WHITE}--- 系统与网络 ---${NC}"; echo -e "${WHITE}11. 网络设置${NC}"; echo -e "${WHITE}12. 常用命令${NC}"; echo -e "${WHITE}13. 更换XanMod内核${NC}"; echo -e "${WHITE}14. 网络优化${NC}"; echo -e "${RED}15. 卸载Sbshell${NC}"; echo -e "${GREEN} 0. 退出${NC}"; }
handle_client_choice() { local choice; read -rp '请选择操作: ' choice; case "$choice" in 1) run_script '配置代理模式' switch_mode.sh && run_script '配置订阅链接' manual_input.sh && run_script '启动 sing-box' start_singbox.sh;; 2) run_script '手动更新配置' manual_update.sh;; 3) run_script '自动更新配置' auto_update.sh;; 4) run_script '设置默认参数' set_defaults.sh;; 5) run_script '启动sing-box' start_singbox.sh;; 6) run_script '停止sing-box' stop_singbox.sh;; 7) run_script '管理自启动' manage_autostart.sh;; 8) if command -v sing-box >/dev/null 2>&1; then run_script '检查 sing-box 更新' check_update.sh; else run_script '安装/更新 sing-box' install_singbox.sh; fi;; 9) run_script '更新所有脚本' update_scripts.sh;; 10) run_script '更新控制面板' update_ui.sh;; 11) run_script '网络设置' set_network.sh;; 12) run_script '常用命令' commands.sh;; 13) run_script '更换XanMod内核' kernel.sh;; 14) run_script '网络优化' optimize.sh;; 15) uninstall_sbshell;; 0) exit 0;; *) echo -e "${RED}无效的选择。${NC}";; esac; }
show_server_menu() { echo -e "\n${CYAN}================= sbshell服务端管理菜单 =================${NC}"; echo '1. 启动sing-box'; echo '2. 停止sing-box'; echo '3. 重启sing-box'; echo '4. 设为自启'; echo '5. 查看日志'; echo '6. 更新配置文件'; echo '7. 更新sing-box'; echo '8. 更新脚本'; echo '9. 证书申请'; echo '10. 更换XanMod内核'; echo '11. 网络优化'; echo '12. 手动配置防火墙'; echo '13. 卸载Sbshell'; echo '0. 退出'; }
handle_server_choice() { local choice; read -rp '请选择操作: ' choice; case "$choice" in 1) run_systemctl 启动sing-box start;; 2) run_systemctl 停止sing-box stop;; 3) run_systemctl 重启sing-box restart;; 4) run_systemctl 设置开机自启 enable;; 5) journalctl -u sing-box --output cat -f;; 6) run_script 更新服务端配置文件 update_config.sh;; 7) if command -v sing-box >/dev/null 2>&1; then run_script 检查\ sing-box\ 更新 check_update.sh; else run_script 安装/更新\ sing-box install_singbox.sh; fi;; 8) run_script 更新脚本 update_scripts.sh;; 9) run_script 证书申请 setup.sh;; 10) run_script 更换XanMod内核 kernel.sh;; 11) run_script 网络优化 optimize.sh;; 12) run_script 手动配置防火墙 ufw.sh;; 13) uninstall_sbshell;; 0) exit 0;; *) echo -e "${RED}无效选择。${NC}";; esac; }
main() {
    require_cmd curl
    install -d -o root -g root -m 0755 /etc/sing-box "$SCRIPT_DIR"
    cd "$SCRIPT_DIR"
    [ "${1:-}" = menu ] && shift || true
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
        *)
            echo -e "${RED}角色无效: $ROLE${NC}" >&2
            exit 1
            ;;
    esac
}
main "$@"
