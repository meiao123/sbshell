#!/bin/bash
# 一键申请 SSL 证书脚本
set -eEuo pipefail
trap 'echo -e "\033[31m脚本在 [${BASH_SOURCE}:${LINENO}] 行发生错误\033[0m" >&2; exit 1' ERR

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BOLD='\033[1m'; RESET='\033[0m'
DOMAIN=''; EMAIL=''; CA_SERVER=letsencrypt; OS_TYPE=''; PKG_MANAGER=''; ACME_INSTALL_PATH="$HOME/.acme.sh"; CERT_KEY_DIR=''; ACME_CMD=''
ACME_VERSION=3.1.5
ACME_REPO=https://github.com/acmesh-official/acme.sh.git
ACME_SIGNER='github@neilpang.com namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBTjI0HBJn3uhfT2DsNcFybfAZi3ADbIacMpz1BItKdB'
TMP_DIR=$(mktemp -d /tmp/sbshell-acme.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

check_root() {
    [ "$EUID" -eq 0 ] || { echo -e "${RED}错误：请使用 root 权限运行此脚本。${RESET}" >&2; exit 1; }
}
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
    local dependencies=(curl socat)
    if [[ "$PKG_MANAGER" == apt ]]; then dependencies+=(cron ufw git openssh-client); else dependencies+=(cronie firewalld git openssh-clients); fi
    for pkg in "${dependencies[@]}"; do
        if [[ "$PKG_MANAGER" == apt ]]; then
            dpkg -s "$pkg" &>/dev/null || sudo apt-get update -qq && sudo apt-get install -y "$pkg" >/dev/null
        else
            rpm -q "$pkg" &>/dev/null || sudo yum install -y "$pkg" >/dev/null
        fi
    done
}
configure_firewall() {
    local firewall_cmd firewall_service_name ssh_port
    read -r -p '请输入需要开放的 SSH 端口(默认 22): ' ssh_port; ssh_port=${ssh_port:-22}
    [[ "$ssh_port" =~ ^[0-9]+$ && "$ssh_port" -ge 1 && "$ssh_port" -le 65535 ]] || { echo -e "${RED}SSH 端口无效。${RESET}" >&2; exit 1; }
    if [[ "$OS_TYPE" == ubuntu || "$OS_TYPE" == debian ]]; then
        firewall_cmd=ufw; firewall_service_name=ufw
        sudo "$firewall_cmd" status | grep -q inactive && echo y | sudo "$firewall_cmd" enable >/dev/null 2>&1 || true
        sudo "$firewall_cmd" allow "$ssh_port"/tcp >/dev/null
        sudo "$firewall_cmd" allow 80/tcp >/dev/null
        sudo "$firewall_cmd" allow 443/tcp >/dev/null
    else
        firewall_cmd=firewall-cmd; firewall_service_name=firewalld
        sudo systemctl is-active --quiet "$firewall_service_name" || sudo systemctl start "$firewall_service_name"
        sudo "$firewall_cmd" --zone=public --add-port="$ssh_port"/tcp --permanent >/dev/null
        sudo "$firewall_cmd" --zone=public --add-port=80/tcp --permanent >/dev/null
        sudo "$firewall_cmd" --zone=public --add-port=443/tcp --permanent >/dev/null
        sudo "$firewall_cmd" --reload >/dev/null
    fi
}
download_acme() {
    [ -d "$ACME_INSTALL_PATH" ] && return 0
    local clone_dir="$TMP_DIR/acme.sh" allowed_signers="$TMP_DIR/allowed_signers"
    printf '%s\n' "$ACME_SIGNER" > "$allowed_signers"
    git clone --depth 1 --branch "$ACME_VERSION" "$ACME_REPO" "$clone_dir" >/dev/null 2>&1
    git -C "$clone_dir" config gpg.ssh.allowedSignersFile "$allowed_signers"
    git -C "$clone_dir" verify-tag "$ACME_VERSION" >/dev/null 2>&1 || { echo -e "${RED}acme.sh 签名验证失败。${RESET}" >&2; exit 1; }
    bash "$clone_dir/acme.sh" --install --home "$ACME_INSTALL_PATH" -m "$EMAIL" >/dev/null
    echo -e "${GREEN}acme.sh $ACME_VERSION 已通过签名验证并安装。${RESET}"
}
find_acme_cmd() {
    export PATH="$ACME_INSTALL_PATH:$PATH"
    ACME_CMD=$(command -v acme.sh || true)
    [ -n "$ACME_CMD" ] || { echo -e "${RED}找不到 acme.sh。${RESET}" >&2; exit 1; }
}
update_acme() {
    echo -e "${GREEN}使用固定签名版本 acme.sh $ACME_VERSION，不自动执行远程自更新。${RESET}"
}
issue_cert() {
    "$ACME_CMD" --issue --standalone -d "$DOMAIN" --server "$CA_SERVER" --force \
        --pre-hook 'systemctl stop nginx 2>/dev/null || systemctl stop apache2 2>/dev/null || true' \
        --post-hook 'systemctl start nginx 2>/dev/null || systemctl start apache2 2>/dev/null || true' >/dev/null 2>&1 || {
        echo -e "${RED}证书申请失败。${RESET}" >&2; exit 1;
    }
}
install_cert() {
    CERT_KEY_DIR="/etc/ssl/$DOMAIN"
    sudo install -d -m 0755 "$CERT_KEY_DIR"
    sudo "$ACME_CMD" --installcert -d "$DOMAIN" --key-file "${CERT_KEY_DIR}/${DOMAIN}.key" --fullchain-file "${CERT_KEY_DIR}/${DOMAIN}.crt" --reloadcmd 'systemctl reload nginx 2>/dev/null || systemctl reload apache2 2>/dev/null || true' >/dev/null 2>&1 || { echo -e "${RED}证书安装失败。${RESET}" >&2; exit 1; }
    sudo chmod 600 "${CERT_KEY_DIR}/${DOMAIN}.key"
    sudo chown root:root "${CERT_KEY_DIR}/${DOMAIN}.key"
}

check_root
get_user_input
detect_os
install_dependencies
configure_firewall
download_acme
find_acme_cmd
update_acme
issue_cert
install_cert
sudo "$ACME_CMD" --install-cronjob >/dev/null 2>&1 || echo -e "${YELLOW}自动续期任务配置失败，请手动检查。${RESET}" >&2

echo -e "${GREEN}证书文件: ${BOLD}${CERT_KEY_DIR}/${DOMAIN}.crt${RESET}"
echo -e "${GREEN}私钥文件: ${BOLD}${CERT_KEY_DIR}/${DOMAIN}.key${RESET}"
