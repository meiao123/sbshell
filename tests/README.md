# 行为测试（tests/）

`security_regression.sh` 那套纯文本 grep 断言已经被删除：它只能证明“代码里出现过某个
字符串”，对运行期缺陷（trap + set -u、锁不释放、状态机不对称、errexit 被关闭……）
完全无感。

现在的测试是**在容器里以 root 运行仓库里的真实脚本**，只用 stub 替换外部依赖：

```
tests/run.sh            # 构建镜像 + 运行全部套件（推荐 / CI）
tests/run.sh --local    # 在本地 Linux 主机以 root 直接运行
```

没有 docker/podman 时 `run.sh` 会明确报错并给出替代方案（不会静默跳过）。

## 结构

| 路径 | 作用 |
| --- | --- |
| `Dockerfile` | debian:12-slim + bash/coreutils/jq/unzip/util-linux，把 stub 与测试拷进镜像 |
| `all.sh` | 容器内入口：依次执行 `suites/*.sh` 并汇总 |
| `run.sh` | 宿主机入口：构建镜像、以只读方式挂载仓库到 `/src` |
| `lib/harness.sh` | 断言、状态重置、脚本安装等公共函数 |
| `fakebin/` | `nft` `ip` `systemctl` `sing-box` `curl` `sysctl` `ss` `pidof` `opkg` `apk` `uci` `logread` `ufw` `sshd` 等 stub |
| `fakebin-busybox/` | 模拟 busybox `grep`（不支持 `-P`），用于 OpenWrt 兼容性测试 |
| `rc.common` / `initd/` | 极简 `/etc/rc.common` 与 OpenWrt 风格 init 脚本（`sing-box` 极简桩、`sing-box-package` 复刻包里的 UCI 门控桩） |
| `suites/` | 13 个行为测试套件 |

状态都保存在 `$SBSHELL_STUB_STATE`（默认 `/tmp/sbshell-stub-state`），断言直接检查
nft 表、ip rule/route、state 文件、锁目录、cron 文件等可观测结果。

`fakebin/curl` 支持失败注入与慢速模拟：`SBSHELL_CURL_FAIL=<curl 退出码>` 让本次请求按该退出码
失败，`SBSHELL_CURL_HTTP=<状态码>` 决定 `-w '%{http_code}'` 回报的状态码，
`SBSHELL_CURL_SLEEP=<秒>` 让请求慢下来（用于确定性断言 30s 下载倒计时真的在走）。

`initd/sing-box` 与 `initd/sing-box-package` 支持 `SBSHELL_INITD_NOISE=1`：让服务脚本按真机
原样吐出两种 ubus 噪音（短形态 `Command failed: Not found` 与带命令名的长形态），用于验证
各入口的噪音过滤。

`fakebin/uci` 只实现仓库用到的那部分 UCI（`-q get/set/commit`），状态落在
`$SBSHELL_STUB_STATE/uci/<config>`；配合 `initd/sing-box-package`（复刻包里的
`sing-box.main.enabled` 门控）用来守住「保留了包管理器服务脚本，却没打开 UCI 开关
→ `start` 返回 0 但 sing-box 静默不启动」这个真机缺陷。

## 套件与审计项的对应关系

| 套件 | 覆盖的审计项 |
| --- | --- |
| `01_debian_menu_flow.sh` | P0-1（RETURN trap 使菜单中止） |
| `02_mode_state.sh` | P1-3.1 TProxy/TUN 对称清理、P1-3.4 fwmark 精确匹配、P1-3.5 快照恢复、P2-7 TUN 表收窄、回滚与外来表拒绝 |
| `03_locks.sh` | P0-3 锁不释放、P2-18 锁/临时文件清理、debian flock 并发 |
| `04_config_update.sh` | P1-3.2 空后端地址、P1-3.3 参数语义、P2-15 订阅校验、P2-1 服务端凭据本地生成、配置更新原子性 |
| `05_openwrt.sh` | P0-4 开机防火墙恢复、P1-3.6 busybox grep、P1-3.7 initialize 失败传播、P2-13 kmod-tun、包管理器 init 脚本的 UCI 启用开关、各入口过滤 ubus `Command failed: … Not found` 噪音（短形态与带命令名的长形态都算，均为真机回归）、兼容性坏配置不再中断初始化、模板 DNS 用 1.12 写法 |
| `06_misc.sh` | P0-2 cpuinfo flags、P1-3.8 环境/优化/延迟测试、P2-6 ufw 端口、P2-4 固定发布引用 |
| `07_no_install.sh` | 真机回归（ImmortalWrt）：busybox 没有 `install` applet 时，一键引导与 OpenWrt 脚本仍须可用（含生成的 cron 脚本） |
| `10_package_manager.sh` | 真机回归（ImmortalWrt 25.12.2 / apk-tools 3.0.5）：OpenWrt 25.12 起 apk 取代 opkg，安装/UI 更新/引导/卸载四处都须按可用包管理器分派，且老固件的 opkg 调用序列不变 |
| `11_download_failure_reason.sh` | 真机回归（ImmortalWrt 25.12.2）：`set -Eeuo pipefail` + 后台子 shell 跑 curl 时，errexit 会在 curl 失败时跳过状态写入，导致后端 HTTP 500 被误报成“配置文件下载超时”；现在失败必须立刻给出真实原因（HTTP 状态 / DNS / 连接被拒绝 / curl 超时）并打印请求地址，且现有配置不被改动 |
| `12_ui_install.sh` | 真机回归（ImmortalWrt 25.12.2）：① 安装流程必须主动安装默认 UI（配置下载/启动失败也要装，否则 UI 永远装不上）；② UI 的完成通知或失败警告必须先于主菜单出现，且 UI 失败不能挡住菜单；③ 配置下载/更新统一 30s 超时并显示倒计时（`manual_update.sh` 与 `auto_update.sh` 的 cron 脚本，cron 下用 `[ -t 1 ]` 静默） |
| `13_batch1_hardening.sh` | 批次 1 安全回归：`--local` 未确认必须拒绝、acme.sh 固定提交校验、配置 0640、临时目录 mktemp、OpenWrt 仅 HTTPS |
| `14_batch2_integrity.sh` | 批次 2 数据完整性：`install()` 兜底必须先 unlink（否则覆盖运行中的脚本）、cron 更新备份移出 `$TMP`、配置原子替换 |
| `15_ui_atomic_deploy.sh` | 批次 2 F8：UI 部署必须同文件系统 staging + rename，回滚前显式删除目标 |
| `16_guardrails.sh` | 批次 3 测试护栏：空套件集/忘记 `suite_end` 必须判失败、断言失败带实际输出、nft 桩保真度 |

## 本地开发

在 Linux 上快速迭代：

```sh
# --local 会在宿主机上模拟安装（删除/覆盖真实 /etc 路径），必须显式确认
sudo SBSHELL_ALLOW_LOCAL_DESTRUCTIVE=1 tests/run.sh --local
```

只想跑某个套件：

```sh
sudo env SBSHELL_SRC="$PWD" SBSHELL_TEST_ROOT="$PWD/tests" \
  PATH="$PWD/tests/fakebin:$PATH" bash tests/suites/02_mode_state.sh
```

注意：`--local` 直接操作宿主机的真实路径 —— 删除并重建 `/etc/sing-box`、`/etc/rc.d`、
`/etc/crontabs`，覆盖 `/etc/init.d/sing-box` 与 `/etc/init.d/cron`，覆写 `/etc/ssh/sshd_config`，
并在需要时临时安装 `/etc/rc.common`。未设置 `SBSHELL_ALLOW_LOCAL_DESTRUCTIVE=1` 时它**默认拒绝运行**
并列出上述路径；确认后会由 `tests/lib/host_guard.sh` 把 `tests/lib/host_guard.sh` 中列出的路径整体备份到
`SBSHELL_LOCAL_BACKUP`（默认 `/var/tmp/sbshell-host-backup.<时间戳>`）并在退出时恢复。
被 `kill -9` 或断电时仍可能残留，因此**请只在一次性容器/虚拟机里使用**。
