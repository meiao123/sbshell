# Sbshell
⚠️⚠️请注意禁止搬运到中国大陆，请遵守属地法律法律⚠️⚠️  
Sbshell 是一款针对 官方sing-box 的辅助运行脚本，旨在让官方sing-box更方便使用：

- **系统支持**：支持系统为Debian/Ubuntu/Armbian以及OpenWrt。
- **客户端运行**：客户端保持 sing-box 以官方裸核形式运行，追求极致精简与性能。
- **服务端运行**：支持服务端配置搭建使用，使用方法自行google油管教程和翻阅sing-box官方文档。
- **双模支持**：兼容 TUN 和 TProxy 模式，可随时一键切换，灵活适应不同需求。
- **版本管理**：支持一键切换稳定版与测试版内核，检测并更新至最新版本，操作简单高效。
- **灵活配置**：支持手动输入后端地址、订阅链接、配置文件链接，并可设置默认值，提升使用效率。
- **订阅管理**：支持手动更新、定时自动更新，确保订阅和配置始终保持最新。
- **启动控制**：支持手动启动、停止和开机自启管理，操作直观。
- **网络配置**：内置网络配置模块，可快速修改系统 IP、网关和 DNS，自动提示是否需要调整。
- **便捷命令**：集成常用命令，避免手动查找与复制的繁琐。
- **在线更新**：支持脚本在线更新，始终保持最新版本。
- **代码来源**：一键安装与脚本自更新直接使用 `main` 分支当前代码，不再使用 `RELEASE` 发布指针；`main` 是唯一的在线更新源。
- **面板更新**：支持clash系面板在线更新/切换。


## 设备支持：

目前支持系统为deiban/ubuntu/armbian以及openwrt！

## 一键脚本：(请自行安装curl和bash，如果缺少的话)
```
bash <(curl -sL https://raw.githubusercontent.com/meiao123/sbshell/refs/heads/main/sbshall.sh)
```
- 初始化运行结束，输入“**sb**”进入菜单
- 目前支持系统为deiban/ubuntu/armbian/openwrt。  
- 防火墙仅支持nftables，不支持iptables。
- 非openwrt并使用2.1.2之前版本的用户想要升级并且使用1.12.X版本内核建议卸载重装

### 系统信息自动显示美化脚本： 
```
bash <(curl -sL https://gh-proxy.com/https://raw.githubusercontent.com/qljsyph/DPInfo-script/refs/heads/main/auto-sysinfo.sh)
```
  执行后每次进入ssh会自动显示很多必要信息！
  仓库：  
  https://github.com/qljsyph/DPInfo-script

## 适配配置文件：

### 发行版1.12:
fakeiptrpoxy:
https://raw.githubusercontent.com/meiao123/sbshell/91865d43c91b5d22141d412c27d3c54624c4be95/config_template/config_fakeiptrpoxy12.json

fakeiptun:
https://raw.githubusercontent.com/meiao123/sbshell/91865d43c91b5d22141d412c27d3c54624c4be95/config_template/config_fakeiptun12.json

tproxy:
https://raw.githubusercontent.com/meiao123/sbshell/91865d43c91b5d22141d412c27d3c54624c4be95/config_template/config_trpoxy12.json

### 发行版1.11：  
tproxy：  
https://raw.githubusercontent.com/meiao123/sbshell/91865d43c91b5d22141d412c27d3c54624c4be95/config_template/config_tproxy.json  

tun：  
https://raw.githubusercontent.com/meiao123/sbshell/91865d43c91b5d22141d412c27d3c54624c4be95/config_template/config_tun.json  

## 安全与运维说明：

- **服务端凭据请本地生成**：仓库里的 `config_template/server/config.json` 只是字段参考
  （带 `REPLACE_ME_*` 占位符，`sing-box check` 不会通过）。请使用
  `debian/gen_server_config.sh`（菜单 → 服务端 → 6. 更新服务端配置文件 → 直接回车），
  它会在本机随机生成 SS 密码 / VLESS UUID / REALITY 密钥对 / hysteria2 密码，并在写入前
  做 `sing-box check`。
- **控制面板默认只监听本机**：客户端模板的 `clash_api.external_controller` 已改为
  `127.0.0.1:9095`、`secret` 为空。需要从局域网访问面板时，请自行改成 `0.0.0.0:9095`
  并**同时设置一个随机 `secret`**，否则同网段任何人都能控制代理；更安全的做法是保持本机
  监听并用 SSH 端口转发。
- **面板下载地址**：`update_ui.sh` 内置的是固定 commit 的三个面板地址；配置里的
  `external_ui_download_url` 会被“默认 UI”选项优先使用，模板里那个地址走第三方代理且是
  可变分支，介意供应链风险时请固定到自己可控的地址。
- **缓存文件**：配置里的 `cache_file` 指向 `/etc/sing-box/cache.db`。服务以 `sing-box`
  用户运行而该目录属主是 root，安装脚本会预创建该文件并交给 `sing-box` 用户；手工替换
  配置时请保留这个前提（或改到 `/var/lib/sing-box/`）。
- **自定义 SSH 端口**：服务端初始化会先探测当前 sshd 端口再开启 ufw 的
  `default deny incoming`，但仍建议在控制台旁操作，避免误锁自己。
- **开机自启动**：nftables 规则不跨重启保留。Debian 侧由 `nftables-singbox.service`
  恢复，OpenWrt 侧由 `/etc/init.d/sbshell-firewall` 恢复（启用自启动时自动安装），
  两平台都不需要手工重新下发规则。

## 其他问题：

**请查看[wiki](https://github.com/qljsyph/sbshell/wiki)**  
**网络优化功能不懂的不要使用会影响游戏性**


