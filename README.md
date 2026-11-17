# Sbshell
⚠️⚠️请注意禁止搬运到中国大陆，请遵守属地法律法律⚠️⚠️  
Sbshell 是一款针对 官方sing-box 的辅助运行脚本，旨在让官方sing-box更方便使用：

- **系统支持**：仅支持 OpenWrt / ImmortalWrt（Debian / Ubuntu / Armbian 支持已移除）。
- **客户端运行**：客户端保持 sing-box 以官方裸核形式运行，追求极致精简与性能。
- **双模支持**：兼容 TUN 和 TProxy 模式，可随时一键切换，灵活适应不同需求。
- **版本管理**：支持一键切换稳定版与测试版内核，检测并更新至最新版本，操作简单高效。
- **上游包下载可见**：安装上游 sing-box 时每 2 秒显示已下载大小；连接低速/卡死会在 30 秒内自动放弃并回退发行版包，不再静默等满 5 分钟。总大小优先取 GitHub API，API 被限流/被拦时用 `HEAD` 的 `Content-Length` 兜底，仍能显示「已下载 / 总量」。
- **灵活配置**：支持手动输入后端地址、订阅链接、配置文件链接，并可设置默认值，提升使用效率。
- **订阅管理**：支持手动更新、定时自动更新，确保订阅和配置始终保持最新。
- **启动控制**：支持手动启动、停止和开机自启管理，操作直观。
- **网络配置**：内置网络配置模块，可快速修改系统 IP、网关和 DNS，自动提示是否需要调整。
- **便捷命令**：集成常用命令，避免手动查找与复制的繁琐。
- **在线更新**：支持脚本在线更新，始终保持最新版本。
- **后端可选本地构建**：菜单 12 可在路由器上用 Docker 本地构建并部署
  [Toperlock/sing-box-subscribe](https://github.com/Toperlock/sing-box-subscribe) 后端（固定上游 commit、
  健康检查、端到端 `sing-box check` 校验，失败自动回滚旧容器）。
- **代码来源**：一键安装与脚本自更新直接使用 `main` 分支当前代码，不再使用 `RELEASE` 发布指针；`main` 是唯一的在线更新源。
- **完整性校验**：每次自更新都会先取仓库根的 `SHA256SUMS`，逐文件核对 SHA-256 后才安装；校验失败即中止并保留现有安装。设备上没有 `sha256sum` 时会尝试 `busybox sha256sum`；两者都没有时打印警告并跳过校验（精简 busybox 上的既有取舍）。清单必须覆盖下载目录里的每个脚本，缺条目同样拒绝安装。
- **面板适配**：优先适配 sing-box 1.14+ 原生 API + Dashboard；旧版 `experimental.clash_api` 的 Zashboard/MetaCubeXD/YACD 管理仍保留，仅在旧配置下启用。


## 设备支持：

目前支持 **OpenWrt / ImmortalWrt**。

- Debian / Ubuntu / Armbian 相关的脚本、模板与测试已整体移除，仓库只保留 OpenWrt 路径。
- 依赖：需要 `bash` 与 `curl`（一键脚本本身就是 bash 脚本）；面板解压需要 `unzip`，缺失时安装面板会按需通过 `apk`/`opkg` 自动安装，装不上则中止并说明原因。
- 防火墙仅支持 nftables，不支持 iptables；TUN 模式需要内核提供 `/dev/net/tun`。菜单里的「环境检查」会直接报出 `sing-box` 版本、`nft` 是否可用以及 `/dev/net/tun` 是否存在。
- **TProxy 模式目前只代理 IPv4**：`configure_tproxy.sh` 在两条链首行显式 `meta nfproto ipv6 return`，IPv6 流量既不代理也不被拦截（避免落到没人监听的 tproxy 端口）。需要代理 v6 请用 TUN 模式。
- **内核版本与模板要匹配**：ImmortalWrt 25.12 的 feed 包是 sing-box 1.12.25，而仓库默认模板要求 1.14+（`services[].type=api`、`http_clients`）。安装脚本会在检测到内核低于 1.14 时告警；请改用 1.12 兼容模板，或保证能连 GitHub 安装上游最新版。
- **装内核的版本解析不依赖 API 配额**：安装上游 sing-box 时先跟随 `github.com/.../releases/latest` 的 302 解析
  最新版本（**不消耗** `api.github.com` 的 60 次/小时/IP），API 只用于可选的 sha256(digest) 校验；被限流时
  仍能装最新版（仅跳过 digest 校验，已用 HTTPS）。两个可选开关：`SBSHELL_SINGBOX_VERSION=1.14.4`
  （固定版本：跳过全部解析、直接按版本拼地址，适合可复现部署）、`SBSHELL_GITHUB_TOKEN=...`
  （API 配额提升到 5000 次/小时；token 只从环境变量读，经 0600 临时配置文件传给 curl，不进命令行/不落盘）。
- 已在 ImmortalWrt 25.12.2 上实际使用；真机上踩到的问题（busybox 没有 `install`、HTTP 500 被误报成下载超时等）与修法都记在 `openwrt/` 内的注释里。
- 自定义固件请确认已包含 nftables 与 tun 相关内核模块（`kmod-nft-tproxy`、`kmod-tun` 等）。

## 一键脚本：(请自行安装curl和bash，如果缺少的话)
```
bash <(curl -fsSL https://raw.githubusercontent.com/meiao123/sbshell/refs/heads/main/sbshall.sh)
```
- 用 `-fsSL`（`-f`）而不是 `-sL`：拉取失败会**当场报错**。若用 `-sL`，`raw.githubusercontent.com`
  被重置/限流时会返回空内容，`bash` 读到 EOF 就**静默退出**（看起来像"没反应"）。
- 若 raw 反复失败（`curl: (35) SSL/TLS handshake`、超时、`403`），改用 `github.com` 本体下载完整包：
```
cd /tmp && rm -rf sbshell-main sb.tgz
curl -fL -o sb.tgz https://github.com/meiao123/sbshell/archive/refs/heads/main.tar.gz
tar -xzf sb.tgz && cd sbshell-main && sha256sum -c SHA256SUMS && bash sbshall.sh
```
- 初始化运行结束，输入“**sb**”进入菜单
- 目前支持系统为 OpenWrt / ImmortalWrt。
- 防火墙仅支持nftables，不支持iptables。

## 后端（sing-box-subscribe）：可选本地构建

Sbshell 只负责客户端；配置由你自己的「后端 + 订阅 + 模板」生成。后端需实现这个接口
（与 [Toperlock/sing-box-subscribe](https://github.com/Toperlock/sing-box-subscribe) 一致）：

```
GET /config/<订阅URL>&file=<模板URL>
```

菜单 **12「部署/重建后端（Docker 本地构建）」** 会：校验 docker 与磁盘 → 拉取固定 commit 的源码 →
`docker build` → 以 `--network host` 启动 `sbshell-backend` 容器 → 健康检查 `127.0.0.1:5000/` →
按当前模式选模板、用已保存的订阅实际生成一次配置并 `sing-box check`（只探测刚部署的本机后端）。构建/启动失败会**保留或回滚旧容器**，不会把
能用的后端换成一个起不来的。

初始化流程（`sb` 首次运行）也会在**装完 UI 之后、选择模式之前**自动执行一次这个构建，
避免"后端没起就去拉配置"必然失败。以下情况会自动跳过：本机后端已在运行、默认后端不是
本机（`127.0.0.1`/`localhost`）、后端地址被显式留空（纯模板直连）、没装 docker；设置
`SBSHELL_SKIP_BACKEND_BUILD=1` 可强制跳过。
构建失败只告警，初始化继续（之后可用菜单 12 重试）。

- 只构建不动容器：`deploy_backend.sh --build-only`；跳过端到端校验：`--skip-e2e`；
  跟随上游最新：`--ref main`（默认固定 commit，可复现）。也可以让菜单 12 跟随：
  `SBSHELL_BACKEND_REF=main sb`（不设该变量时仍用固定 commit；ref 只允许字母、数字、`.`、`_`、`/`、`-`）。
- **版本可见**：每次构建前打印「固定版本 / 本次使用 / 上游最新（用 atom feed 取，不耗 API 配额）」，
  固定版本落后时会提示；部署成功后把实际 ref 记到 `/etc/sing-box/backend.ref`，下次切换版本
  （例如先用 `main` 试装、又点菜单 12）会明确提示"本次将切换为 …"，避免无声降级。
- 构建期间每 30 秒打印一次心跳（`SBSHELL_BACKEND_BUILD_HEARTBEAT`），并默认在
  **1800 秒**后中止（`SBSHELL_BACKEND_BUILD_TIMEOUT`）——Docker 自身没有构建超时。
- 预检会探测 `registry-1.docker.io`：不可达时**不强制 `--pull`**（用本地缓存的基础镜像），
  避免"本地已有镜像却因拉取失败而构建不了"；国内建议在 `/etc/docker/daemon.json` 配
  `registry-mirrors` 后重启 dockerd。
- 官方没有发布镜像，社区镜像年久失修（旧版解析 base64 订阅会直接 500），因此默认走本地构建。
- 后端是单线程 Flask：订阅很大时生成可能超过选项 2 的 30 秒下载超时，届时先手动 `curl` 验证后端。
- **模板版本**：本项目要求 sing-box **1.14+**。出厂模板地址经 `https://gh-proxy.com/` 代理
  （`raw.githubusercontent.com` 在国内常被 TLS 干扰，表现为 `unexpected eof while reading`）；若该代理
  不可用，可在菜单 6 换回 raw 地址或改用 `https://ghproxy.net/` 前缀。出厂模板为
  `singbox/configuration/1.14.x/config_sb_Tun_fakeip.json`；上游文件名带 `1.2.x` 的是历史命名，
  内容早已按 1.14 适配，仓库中保留旧路径仅为兼容旧引用。

## 安全与运维说明：

- **不含服务端搭建**：服务端配置生成脚本（`gen_server_config.sh`）与 `config_template/server/`
  已随 Debian/Ubuntu 支持一并移除。本仓库只管理客户端；如需服务端，请按 sing-box
  官方文档自行编写配置，并在写入前用 `sing-box check` 校验。
- **当前控制面板（sing-box 1.14+）**：当前 TUN 配置使用 `services[].type=api`，监听 `9090`，
  Dashboard 由 sing-box 原生提供在 `/dashboard/`，并由 `dashboard.update_interval` 管理更新；默认未填写
  时 sing-box 使用 `1d`。当前示例配置监听 `0.0.0.0:9090` 且 `secret` 为空，**这会关闭 API 身份认证**，
  不建议直接暴露给不可信网络。需要局域网访问时，请设置随机 `secret`；更严格时将 `listen` 改为
  `127.0.0.1` 并通过 SSH 端口转发访问。旧版 `experimental.clash_api` 仍可由 Sbshell 兼容处理。
- **旧版 Clash UI 下载地址**：仅当配置仍使用 `experimental.clash_api.external_ui` 时，默认 UI **不固定版本** —— 安装时会查询 zashboard 的最新 release
  （`/releases/latest` 自动排除 prerelease），优先取其中的 `dist-cdn-fonts.zip`（没有则取任意
  `dist-*.zip`）；查询失败或没有合适资产时回退到内置的固定地址，保证「拿不到最新版」不会变成
  「装不上」。**注意**：配置里的 `external_ui_download_url` 会**优先于**这套自动解析被“默认 UI”
  使用 —— 想始终拿最新，就把配置里那一行删掉（本仓库自带模板已删除该项）；填死版本号等于永远
  固定在该版本。
- **凭据不出现在输出里**：订阅地址含 token，所有日志/报错只显示 `scheme://host/***`（`lib.sh` 的
  `redact_url`），避免终端回滚、截图或贴日志时把 token 带出去。
- **脚本完整性校验**：仓库根的 `SHA256SUMS` 覆盖 `sbshall.sh`、`openwrt/*.sh` 与公共库 `openwrt/lib.sh`，自更新会在
  安装前逐文件核对；CI 也会比对清单与实际文件，防止清单漂移。它只能防传输损坏与中间层替换，
  **不等于仓库签名**；想更强保证请自行核对 commit（`git log -1`）。
- **获取 main commit 的兜底**：解析当前 `main` 的 commit SHA 时先走 `api.github.com`；未认证 API 只有
  **60 次/小时/IP**，出口 IP 被 CGNAT 或其它工具打满会返回 **403**。此时自动改用 `github.com` 本体
  （`commits/main.atom` → `commit/main.patch` 首行）取同一个 SHA，两者都不可用才中止（仍然 fail-closed，
  绝不从可移动的 `main` 分支下载）。也可以手动指定：
  `SBSHELL_PINNED_COMMIT=<40 位 commit> bash <(curl -fsSL .../sbshall.sh)`；在任意有 git 的机器上用
  `git ls-remote https://github.com/meiao123/sbshell.git refs/heads/main` 可查到最新 SHA。
- **公共实现集中在 `openwrt/lib.sh`**：busybox `install` 兜底、URL/订阅校验、明文 HTTP 提示、默认值解析、
  互斥锁、原子提交（`commit_file`）都只有一份实现，由各入口 `source`。`sbshall.sh`/`menu.sh` 因运行早于
  该库落地、`install_singbox.sh` 因是 `#!/bin/sh`（busybox ash）、以及 cron 生成体因必须自包含，仍保留
  各自内联副本（有意为之）。缺 `lib.sh` 时入口会明确提示「请先在菜单 9 更新脚本」。
- **脚本更新是目录级原子替换**：整批脚本先装进 `/etc/sing-box/scripts.new.XXXXXX`，再整体 rename 成
  `scripts`，目录里的 `.initialized` 等非脚本文件会一并带过去。中途失败只会是"全旧"，不会出现半新半旧。
- **防火墙状态两阶段提交**：下发规则前先写 `tproxy.state.pending` / `tun.state.pending`，`nft -f` 成功后
  才落正式 state 并删除 pending。若在两步之间断电/被 kill，下一次 `configure_*` 或 `clean_nft.sh` 会把
  `.pending` 当作 Sbshell 所有并回收，不再留下"表在、state 不在"的无主表。
- **面板打开是空白页（PWA 缓存）**：面板是 Vite PWA，浏览器会用 Service Worker 缓存旧页面。
  UI 更新后若打开是空白（但标题栏有内容），请在浏览器里对 `http://<路由器IP>:9095/ui/` 注销
  Service Worker 并清掉该站点的 Cache Storage（或先用无痕窗口验证）—— 这属于浏览器端缓存，
  不是路由器配置问题；每次更新 UI 后都可能需要做一次。
- **缓存文件**：缓存文件默认仍使用 `/etc/sing-box/cache.db`。当前 1.14+ TUN 模板启用 `cache_file.store_dns`；
  旧版模板还可能使用 `store_fakeip`。服务以 `sing-box` 用户运行时，请保留缓存文件的可写权限前提。
- **开机自启动**：nftables 规则不跨重启保留，由 `/etc/init.d/sbshell-firewall` 恢复
  （启用自启动时自动安装），不需要手工重新下发规则；卸载会一并注销该启动项。
- **锁与状态文件**：配置/面板/脚本更新分别用 `/tmp/sbshell-*.lock` 互斥，进程被强杀时下一次
  运行会在超时后接管；`/etc/sing-box/` 下的 `mode.conf`、`tproxy.state`、`tun.state` 决定
  清理时该删哪些 nft 表与路由，**手工删表后请一并清理对应状态文件**，否则后续清理会认为
  没有需要处理的对象。
- **出厂默认地址（菜单 6）**：后端、订阅、TUN 模板的出厂值集中在 `openwrt/lib.sh` 的
  `SBSHELL_FACTORY_*`。首次运行菜单 6 直接回车即写入出厂值；之后再运行菜单 6 用新输入覆盖
  （优先级：本轮输入 > 已保存值 > 出厂值）。**显式留空**（键存在但值为空）不会被改回出厂值，
  这样「清空后端、只用模板直连」的合法状态不会被悄悄改回来。选项 2 现在直接回显订阅地址，
  便于核对（本机/局域网后端下没有打码的必要）。

## 其他问题：

**请查看[上游 wiki](https://github.com/qljsyph/sbshell/wiki)（第三方内容，仅供参考）**  
**网络优化功能不懂的不要使用会影响游戏性**
