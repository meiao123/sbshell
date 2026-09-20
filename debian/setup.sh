#!/bin/bash
# 一键申请 SSL 证书脚本
set -eEuo pipefail
trap 'echo -e "\033[31m脚本在 [${BASH_SOURCE}:${LINENO}] 行发生错误\033[0m" >&2; exit 1' ERR

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BOLD='\033[1m'; RESET='\033[0m'
DOMAIN=''; EMAIL=''; CA_SERVER=letsencrypt; OS_TYPE=''; PKG_MANAGER=''; ACME_INSTALL_PATH="$HOME/.acme.sh"; CERT_KEY_DIR=''; ACME_CMD=''
ACME_VERSION=3.1.5
# acme.sh 的版本标签是**轻量标签**（GitHub API: refs/tags/3.1.5 的 object.type=commit），
# 而 `git verify-tag` 只接受附注标签对象 —— 旧写法 `git verify-tag 3.1.5` 是恒假条件，
# 证书申请 100% 失败（用户只看到"签名验证失败"）。改为固定提交 SHA 比对：
# 不可变、可离线复核、不依赖标签类型，也不需要 git ≥ 2.34 的 allowedSignersFile 支持。
ACME_COMMIT=d5fc938d80e266dba3239f54cf4665432f17c00b
ACME_REPO=https://github.com/acmesh-official/acme.sh.git
TMP_DIR=$(mktemp -d /tmp/sbshell-acme.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

check_root() { [ "$EUID" -eq 0 ] || { echo -e "${RED}错误：请使用 root 权限运行此脚本。${RESET}" >&2; exit 1; }; }
# 脚本本身要求 root（见 check_root），这里再兜底一次：root 且没安装 sudo 的机器上，
# 旧的 `sudo xxx` 写法会直接 command not found。
as_root() { if [ "$EUID" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

get_user_input() {
    read -r -p '请输入域名: ' DOMAIN
    [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo -e "${RED}域名格式不正确。${RESET}" >&2; exit 1; }
    read -r -p '请输入电子邮件地址: ' EMAIL
    [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || { echo -e "${RED}电子邮件格式不正确。${RESET}" >&2; exit 1; }
}
detect_os() {
    if grep -qi ubuntu /etc/os-release; then OS_TYPE=ubuntu; PKG_MANAGER=apt
    elif grep -qi debian /etc/os-release; then OS_TYPE=debian; PKG_MANAGER=apt
    elif grep -qi centos /etc/os-release; then OS_TYPE=centos; PKG_MANAGER=yum
    elif grep -qi rhel /etc/os-release; then OS_TYPE=rhel; PKG_MANAGER=yum
    else echo -e "${RED}不支持的操作系统。${RESET}" >&2; exit 1; fi
}
install_dependencies() {
    local package
    local dependencies=(curl socat)
    if [[ "$PKG_MANAGER" == apt ]]; then dependencies+=(cron ufw git openssh-client); else dependencies+=(cronie firewalld git openssh-clients); fi
    if [[ "$PKG_MANAGER" == apt ]]; then
        as_root apt-get update -qq
        for package in "${dependencies[@]}"; do dpkg -s "$package" >/dev/null 2>&1 || as_root apt-get install -y "$package" >/dev/null; done
    else
        for package in "${dependencies[@]}"; do rpm -q "$package" >/dev/null 2>&1 || as_root yum install -y "$package" >/dev/null; done
    fi
}
configure_firewall() {
    local firewall_cmd firewall_service_name ssh_port
    read -r -p '请输入需要开放的 SSH 端口(默认 22): ' ssh_port; ssh_port=${ssh_port:-22}
    [[ "$ssh_port" =~ ^[0-9]+$ && "$ssh_port" -ge 1 && "$ssh_port" -le 65535 ]] || { echo -e "${RED}SSH 端口无效。${RESET}" >&2; exit 1; }
    if [[ "$OS_TYPE" == ubuntu || "$OS_TYPE" == debian ]]; then
        firewall_cmd=ufw; firewall_service_name=ufw
        if as_root "$firewall_cmd" status | grep -q inactive; then echo y | as_root "$firewall_cmd" enable >/dev/null 2>&1 || true; fi
        as_root "$firewall_cmd" allow "$ssh_port"/tcp >/dev/null; as_root "$firewall_cmd" allow 80/tcp >/dev/null; as_root "$firewall_cmd" allow 443/tcp >/dev/null
    else
        firewall_cmd=firewall-cmd; firewall_service_name=firewalld
        systemctl is-active --quiet "$firewall_service_name" || as_root systemctl start "$firewall_service_name"
        as_root "$firewall_cmd" --zone=public --add-port="$ssh_port"/tcp --permanent >/dev/null; as_root "$firewall_cmd" --zone=public --add-port=80/tcp --permanent >/dev/null; as_root "$firewall_cmd" --zone=public --add-port=443/tcp --permanent >/dev/null; as_root "$firewall_cmd" --reload >/dev/null
    fi
}
download_acme() {
    local clone_dir="$TMP_DIR/acme.sh" actual
    git clone --depth 1 --branch "$ACME_VERSION" "$ACME_REPO" "$clone_dir" >/dev/null 2>&1 || { echo -e "${RED}acme.sh $ACME_VERSION 下载失败。${RESET}" >&2; exit 1; }
    # 校验下载到的提交与常量一致（浅克隆下 HEAD 即该标签指向的提交）。
    actual=$(git -C "$clone_dir" rev-parse HEAD 2>/dev/null) || actual=''
    [ "$actual" = "$ACME_COMMIT" ] || { echo -e "${RED}acme.sh $ACME_VERSION 提交校验失败（期望 $ACME_COMMIT，实际 ${actual:-未知}）。${RESET}" >&2; exit 1; }
    bash "$clone_dir/acme.sh" --install --home "$ACME_INSTALL_PATH" -m "$EMAIL" >/dev/null
    echo -e "${GREEN}acme.sh $ACME_VERSION 已通过提交校验（$ACME_COMMIT）并刷新安装。${RESET}"
}
find_acme_cmd() { export PATH="$ACME_INSTALL_PATH:$PATH"; ACME_CMD=$(command -v acme.sh || true); [ -n "$ACME_CMD" ] || { echo -e "${RED}找不到 acme.sh。${RESET}" >&2; exit 1; }; }
update_acme() { echo -e "${GREEN}使用固定提交版本 acme.sh $ACME_VERSION，不自动执行远程自更新。${RESET}"; }
issue_cert() {
    "$ACME_CMD" --issue --standalone -d "$DOMAIN" --server "$CA_SERVER" --force --pre-hook 'systemctl stop nginx 2>/dev/null || systemctl stop apache2 2>/dev/null || true' --post-hook 'systemctl start nginx 2>/dev/null || systemctl start apache2 2>/dev/null || true' >/dev/null 2>&1 || { echo -e "${RED}证书申请失败。${RESET}" >&2; exit 1; }
}
install_cert() {
    CERT_KEY_DIR="/etc/ssl/$DOMAIN"; as_root install -d -m 0755 "$CERT_KEY_DIR"
    as_root "$ACME_CMD" --installcert -d "$DOMAIN" --key-file "${CERT_KEY_DIR}/${DOMAIN}.key" --fullchain-file "${CERT_KEY_DIR}/${DOMAIN}.crt" --reloadcmd 'systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || true' >/dev/null 2>&1 || { echo -e "${RED}证书安装失败。${RESET}" >&2; exit 1; }
    as_root chmod 600 "${CERT_KEY_DIR}/${DOMAIN}.key"; as_root chown root:root "${CERT_KEY_DIR}/${DOMAIN}.key"
}
# acme.sh 的 --install 自身通常会装好续期任务；这里再显式装一次，并在不支持该子命令时
# 回退到直接写 crontab，避免“静默没有续期任务”。
install_renewal_cron() {
    if as_root "$ACME_CMD" --install-cronjob >/dev/null 2>&1; then
        echo -e "${GREEN}acme.sh 自动续期任务已配置。${RESET}"
        return 0
    fi
    if command -v crontab >/dev/null 2>&1; then
        if { as_root crontab -l 2>/dev/null | grep -v 'acme.sh --cron'; printf '0 0 * * * %s --cron --home %s > /dev/null\n' "$ACME_CMD" "$ACME_INSTALL_PATH"; } | as_root crontab - 2>/dev/null; then
            echo -e "${GREEN}已通过 crontab 配置 acme.sh 自动续期任务。${RESET}"
            return 0
        fi
    fi
    echo -e "${YELLOW}自动续期任务配置失败，请手动检查。${RESET}" >&2
}

check_root; get_user_input; detect_os; install_dependencies; configure_firewall; download_acme; find_acme_cmd; update_acme; issue_cert; install_cert; install_renewal_cron
echo -e "${GREEN}证书文件: ${BOLD}${CERT_KEY_DIR}/${DOMAIN}.crt${RESET}"
echo -e "${GREEN}私钥文件: ${BOLD}${CERT_KEY_DIR}/${DOMAIN}.key${RESET}"
