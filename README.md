# Sbshell
⚠️⚠️请注意禁止搬运到中国大陆，请遵守属地法律法律⚠️⚠️  
Sbshell 是一款针对 官方sing-box 的辅助运行脚本，旨在让官方sing-box更方便使用：

- **系统支持**：仅支持 OpenWrt / ImmortalWrt（Debian / Ubuntu / Armbian 支持已移除）。
- **客户端运行**：客户端保持 sing-box 以官方裸核形式运行，追求极致精简与性能。
- **双模支持**：兼容 TUN 和 TProxy 模式，可随时一键切换，灵活适应不同需求。
- **版本管理**：支持一键切换稳定版与测试版内核，检测并更新至最新版本，操作简单高效。
- **灵活配置**：支持手动输入后端地址、订阅链接、配置文件链接，并可设置默认值，提升使用效率。
- **订阅管理**：支持手动更新、定时自动更新，确保订阅和配置始终保持最新。
- **启动控制**：支持手动启动、停止和开机自启管理，操作直观。
- **网络配置**：内置网络配置模块，可快速修改系统 IP、网关和 DNS，自动提示是否需要调整。
- **便捷命令**：集成常用命令，避免手动查找与复制的繁琐。
- **在线更新**：支持脚本在线更新，始终保持最新版本。
- **代码来源**：一键安装与脚本自更新直接使用 `main` 分支当前代码，不再使用 `RELEASE` 发布指针；`main` 是唯一的在线更新源。
- **完整性校验**：每次自更新都会先取仓库根的 `SHA256SUMS`，逐文件核对 SHA-256 后才安装；校验失败即中止并保留现有安装。设备上没有 `sha256sum`（精简 busybox）时会打印警告并跳过校验。
- **面板更新**：支持clash系面板在线更新/切换。


## 设备支持：

目前支持 **OpenWrt / ImmortalWrt**。

- Debian / Ubuntu / Armbian 相关的脚本、模板与测试已整体移除，仓库只保留 OpenWrt 路径。
- 依赖：需要 `bash` 与 `curl`（一键脚本本身就是 bash 脚本）；面板解压需要 `unzip`，缺失时安装面板会按需通过 `apk`/`opkg` 自动安装，装不上则中止并说明原因。
- 防火墙仅支持 nftables，不支持 iptables；TUN 模式需要内核提供 `/dev/net/tun`。菜单里的「环境检查」会直接报出 `sing-box` 版本、`nft` 是否可用以及 `/dev/net/tun` 是否存在。
- 已在 ImmortalWrt 25.12.2 上实际使用；真机上踩到的问题（busybox 没有 `install`、HTTP 500 被误报成下载超时等）与修法都记在 `openwrt/` 内的注释里。
- 自定义固件请确认已包含 nftables 与 tun 相关内核模块（`kmod-nft-tproxy`、`kmod-tun` 等）。

## 一键脚本：(请自行安装curl和bash，如果缺少的话)
```
bash <(curl -sL https://raw.githubusercontent.com/meiao123/sbshell/refs/heads/main/sbshall.sh)
```
- 初始化运行结束，输入“**sb**”进入菜单
- 目前支持系统为 OpenWrt / ImmortalWrt。
- 防火墙仅支持nftables，不支持iptables。

## 安全与运维说明：

- **不含服务端搭建**：服务端配置生成脚本（`gen_server_config.sh`）与 `config_template/server/`
  已随 Debian/Ubuntu 支持一并移除。本仓库只管理客户端；如需服务端，请按 sing-box
  官方文档自行编写配置，并在写入前用 `sing-box check` 校验。
- **控制面板默认只监听本机**：客户端模板的 `clash_api.external_controller` 为
  `127.0.0.1:9095`、`secret` 为空。需要从局域网访问面板时，请自行改成 `0.0.0.0:9095`
  并**同时设置一个随机 `secret`**，否则同网段任何人都能控制代理；更安全的做法是保持本机
  监听并用 SSH 端口转发。
- **面板下载地址**：内置默认与 5 份客户端模板都指向 zashboard **v3.28.0 的 release 资产**
  `dist-cdn-fonts.zip`（`releases/download/v3.28.0/…`）—— 带版本号、不可变、是上游官方发布的
  部署产物（比固定某个 `gh-pages` 提交更清楚，也比走第三方镜像可靠）。升级面板时把 URL 里的
  版本号改掉即可。**注意**：配置里的 `external_ui_download_url` 会**优先于**这个内置地址被
  “默认 UI”使用，所以自带配置里的那一项也要一并换成不可变地址，否则仍可能取到镜像上的旧构建
  （真机上出现过：镜像是可变分支的缓存，装出来比上游 release 落后两个小版本）。
- **脚本完整性校验**：仓库根的 `SHA256SUMS` 覆盖 `sbshall.sh` 与 `openwrt/*.sh`，自更新会在
  安装前逐文件核对；CI 也会比对清单与实际文件，防止清单漂移。它只能防传输损坏与中间层替换，
  **不等于仓库签名**；想更强保证请自行核对 commit（`git log -1`）。
- **面板打开是空白页（PWA 缓存）**：面板是 Vite PWA，浏览器会用 Service Worker 缓存旧页面。
  UI 更新后若打开是空白（但标题栏有内容），请在浏览器里对 `http://<路由器IP>:9095/ui/` 注销
  Service Worker 并清掉该站点的 Cache Storage（或先用无痕窗口验证）—— 这属于浏览器端缓存，
  不是路由器配置问题；每次更新 UI 后都可能需要做一次。
- **缓存文件**：配置里的 `cache_file` 指向 `/etc/sing-box/cache.db`。服务以 `sing-box`
  用户运行而该目录属主是 root，安装脚本会预创建该文件并交给 `sing-box` 用户；手工替换
  配置时请保留这个前提（或改到 `/var/lib/sing-box/`）。
- **开机自启动**：nftables 规则不跨重启保留，由 `/etc/init.d/sbshell-firewall` 恢复
  （启用自启动时自动安装），不需要手工重新下发规则；卸载会一并注销该启动项。
- **锁与状态文件**：配置/面板/脚本更新分别用 `/tmp/sbshell-*.lock` 互斥，进程被强杀时下一次
  运行会在超时后接管；`/etc/sing-box/` 下的 `mode.conf`、`tproxy.state`、`tun.state` 决定
  清理时该删哪些 nft 表与路由，**手工删表后请一并清理对应状态文件**，否则后续清理会认为
  没有需要处理的对象。

## 其他问题：

**请查看[上游 wiki](https://github.com/qljsyph/sbshell/wiki)（第三方内容，仅供参考）**  
**网络优化功能不懂的不要使用会影响游戏性**
