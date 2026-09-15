# 安全加固与缺陷修复记录

本文件记录一轮代码审计（边界漏洞 / 逻辑错误 / 需要优化的地方）的结论与修复落点，
便于评审与回归。每一条都给出了：问题 → 修复 → 守护它的行为测试。

测试运行方式见 [tests/README.md](../tests/README.md)：

```sh
tests/run.sh          # 容器化行为测试（CI 使用）
tests/run.sh --local  # Linux 主机以 root 直接运行
```

## P0：会让功能整体不可用的问题

| # | 问题 | 修复 | 测试 |
| --- | --- | --- | --- |
| P0-1 | `debian/menu.sh` / `openwrt/menu.sh` 在函数里用 `trap ... RETURN` 清理临时目录。RETURN trap 会在**同一调用链的父函数返回时再次触发**，此时 `local` 变量已销毁，`set -u` 下直接以 `unbound variable` 中止整个脚本 —— Debian 菜单在安装 sing-box 之前就死，OpenWrt 菜单在 `initialize()` 返回时死 | 改为显式清理 + 单一返回点；`install_ui` 同步处理；`set_network.sh` 的 RETURN trap 换成 EXIT | `suites/01`、`suites/02` |
| P0-2 | `debian/kernel.sh` 用 `awk -F: '$1 == "flags"'` 读 `/proc/cpuinfo`，而该行是 `flags\t\t: ...`，字段带制表符 → 永远不匹配 → XanMod 内核安装必定失败 | 改为按行首匹配 `/^flags/`，并校验 flags 非空 | `suites/06` |
| P0-3 | `openwrt/auto_update.sh` 生成的 cron 脚本用 `rmdir` 删含 pid 的锁目录，必然失败 → 陈旧锁让后续任务空转到 `LOCK_TIMEOUT=900s` | 改用 `rm -rf` | `suites/03` |
| P0-4 | OpenWrt 启用自启动只 `enable/start` 服务，不恢复 nftables 规则（`apply_firewall` 判定被放在交互 `read` 之后且无调用方），重启后 TProxy/TUN 规则全丢、代理静默失效 | 生成并启用 `/etc/init.d/sbshell-firewall`（START=40），先应用规则成功再启用自启动 | `suites/05` |
| P0-5 | `debian/menu.sh` 的脚本清单漏掉 `set_defaults.sh`，菜单第 4 项在新装机器上必然 `No such file or directory` | 补进清单（清单与目录双向核对） | `suites/01` |

## P1：逻辑与状态机缺陷

| # | 问题 | 修复 | 测试 |
| --- | --- | --- | --- |
| P1-3.1 | Debian 侧没有 TUN 表清理（与 OpenWrt 版不对称）→ 切回 TProxy 后 `inet sing-box-tun` 与 `tun/nftables.conf` 永久残留，`clean_nft.sh` 也清不掉 | 按 OpenWrt 版对齐：tproxy 侧快照/删除/回滚自有 TUN 表并校验 `tun.state`；`clean_nft.sh` 清理两张表 + 策略路由 + state | `suites/02` |
| P1-3.2 | `manual_update.sh` / `auto_update.sh`（两平台四处）强制要求非空 HTTPS 后端地址，而 `manual_input.sh` 明确允许留空 → 这类配置永远无法更新 | 统一 `build_full_url()` 语义：后端可空则直接用模板地址 | `suites/04` |
| P1-3.3 | `debian/manual_update.sh` 用 `^[Yy]$` 决定是否交互、却用 `= 'yes'` 决定是否写回 → `yes` 参数形同虚设 | 统一 `PROMPT_FLAG`（y/Y/yes/YES） | `suites/04` |
| P1-3.4 | 规则探测 `$0 ~ "fwmark 0x" mark` 会命中 `fwmark 0x10` → 误判规则已存在，不再创建 mark-1 策略路由 | 按字段精确比较（兼容 `0x1/0xffffffff` 写法） | `suites/02` |
| P1-3.5 | 回滚时 `spec=${line#*: }` 对 `0:<TAB>...` 不生效 → 恢复逻辑是死代码 | `${line#*:}` + 裁剪前导空白 + 校验 pref 为数字 | `suites/02` |
| P1-3.6 | OpenWrt 用 `grep -oP`（busybox grep 无 PCRE）→ MODE 读空，默认模板地址分支直接报“未知的模式” | 改用 `sed -n 's/^MODE=//p'` | `suites/05`（含 busybox grep stub） |
| P1-3.7 | `openwrt/menu.sh` 的 `initialize \|\| exit 1` 让 errexit 在整个函数体内失效 → 任一步失败仍写 `.initialized` | 每步显式 `\|\| return 1` | `suites/05` |
| P1-3.8 | Debian 维护脚本系列：`sysctl` 缺失键中止初始化；`optimize.sh` 用当前 qdisc 值判断 fq 可用性且 `sysctl --system` 失败即中止；`delaytest.sh` 缺 `--max-time` 且日志无限增长；`update_config.sh` 用可变 `main` 分支且空输入清空链接；别名写入 `$HOME/.bashrc` 却只清 `/root/.bashrc` | 容错读取 + 字符串比较、直接尝试设置 fq、`--max-time` + 日志裁剪、固定引用 + 空输入保留原值、统一 `/root/.bashrc` | `suites/04`、`suites/06` |
| P1-3.9 | `setup.sh` 已 `check_root` 却仍依赖 `sudo`；`switch_mode.sh` 无 `set -e`、无目录创建、`tee` 失败也报成功（mode.conf 根本没写） | 新增 `as_root()`；switch_mode 按 OpenWrt 版重写（原子写入、同模式短路、失败回滚）；install/stop 去掉隐含 sudo | `suites/01`（测试镜像刻意不装 sudo） |

## P2：安全加固与供应链

| # | 问题 | 修复 | 测试 |
| --- | --- | --- | --- |
| P2-1 | 服务端模板内置公开的 SS 密码 / VLESS UUID / REALITY 私钥 / hysteria2 密码，且曾是默认下载配置 | 模板改为 `REPLACE_ME_*` 占位（附 `config_template/server/README.md`）；新增 `debian/gen_server_config.sh` 本地随机生成，回车即用 | `suites/04` |
| P2-2 | 客户端模板 `clash_api` 监听 `0.0.0.0:9095` 且 `secret` 为空 | 改为 `127.0.0.1:9095`，README 说明局域网暴露需同时设置 secret | `suites/06`（静态断言）+ README |
| P2-3 | README 指向他人仓库 `main` 分支的模板；发布引用是可移动分支名 | 模板地址改回本仓库固定引用；`.gitattributes` 强制 LF | `suites/06` |
| P2-4 | 脚本自更新只做 HTTPS + `bash -n`，引用是可移动分支 | 发布引用固定到 commit SHA（见下），README 记录发布流程 | `suites/06` |
| P2-5 | 模板 `cache_file` 指向 root 属主的 `/etc/sing-box/cache.db`，而服务以 `sing-box` 用户运行；`config_fakeiptun12.json` 甚至写到 `/etc/momo/run/` | 安装脚本预创建 `cache.db` 并 chown 给 `sing-box`；fakeiptun 模板路径修正 | 安装脚本 + 模板 |
| P2-6 | 服务端默认只放行 22/80/443，而内置配置监听 52021/udp → 该入站被静默挡掉；固定 `ufw allow ssh` 会锁死自定义 SSH 端口的用户 | `ufw.sh` 自动探测 sshd 端口与配置里的 `listen_port` 并放行 | `suites/06` |
| P2-7 | TUN 模式的 nft 表创建 input/forward/output 三个空 `policy accept` 基链，不做任何过滤，只增加同 hook 上的绕过面 | 收窄为仅 `forward` 链 | `suites/02` |
| P2-8 | `systemd-analyze verify <drop-in 文件>` 在部分 systemd 版本上直接失败并中止安装 | 改为校验父 unit `sing-box.service`，失败仅告警；CI 的 `actions/checkout` 固定到存在的 `v5.1.0` | `suites/06` |

## 发布与更新流程（main 最新代码）

脚本自更新与一键引导统一直接读取 `main` 分支，不再存在 `RELEASE` 发布指针。每次执行 README 中的一键命令时，入口脚本本身来自 `main`，随后按同一个 `main` 引用下载对应平台的管理脚本。

更新链路：

```
sbshall.sh
    ↓
main/sbshall.sh
    ↓
main/openwrt/*.sh 或 main/debian/*.sh
```

这套模型取消了“开发代码”和“发布指针”分离导致的旧版本回退问题。对应行为测试会检查更新入口不再读取 `RELEASE`，并确认平台更新路径直接指向 `main`。

## 第二轮复审（针对 `fdbceb9`）修复清单

第二轮把 42 个上游提交与全部脚本重新过了一遍，并由两个独立评审者分别覆盖
「六个 nftables 文件」与「菜单/锁/UI/权限/自更新」。已修复：

| 问题 | 位置 | 修复 |
| --- | --- | --- |
| 自更新引用指向**已被删除的分支** → 一键安装与更新全部 404 | `sbshall.sh`、两个 `menu.sh`、两个 `update_scripts.sh` | 引用改为存在的**不可变提交 SHA**；CI 用 raw URL 校验引用是否存在（`git ls-remote` 只匹配引用名、对 SHA 恒判失败；`git fetch --depth=1` 判定正确但会把检出变成 shallow 仓库）；离线套件要求 40 位 SHA |
| `configure_tun.sh` 先拆除后校验，早期失败无恢复 | 两平台 `configure_tun.sh` | `nft -c` 提前到所有破坏性操作之前；恢复块抽成 `restore_prev()` + `trap … ERR` |
| `clean_nft.sh` 吞掉 `nft delete` 失败并删掉 state、谎报已清理 | 两平台 `clean_nft.sh` | 用 `nft list tables` 判定存在性；删除失败/无法判定即中止并保留 state；清理后复核规则与路由 |
| `INTERFACE=$5` 在 dev-only 默认路由上取到 `link` | 四个 `configure_*.sh` | 按 `dev` 关键字取网卡（PPPoE/WireGuard 机器上 TProxy 从此可用） |
| TProxy 重放失败时旧策略规则/路由不恢复、state 说谎 | 两平台 `configure_tproxy.sh` | 快照并在 `rollback()` 中恢复旧 rule/route |
| TUN 侧清理以“表是否存在”为开关 | 两平台 `configure_tun.sh` | 改为以 `tproxy.state` 所有权为准 |
| `mode.conf` 缺失时 pipefail 让脚本 rc=2 静默中止 | 三个 bash 配置脚本 | 显式吞掉 sed 失败，保持“无 mode.conf 即静默退出 0” |
| Debian 锁文件位于世界可写的 `/run/lock`（符号链接 + O_TRUNC 可清空任意 root 文件） | Debian 四个脚本（含生成的 cron 版） | 锁移到 `/run/sbshell`（0700）、打开前拒绝符号链接、不再 chmod `/run/lock` |
| OpenWrt 锁：活 pid 让 900s 过期判断永不可达；信号不退出；rm 失败忙等 | 四个 OpenWrt 脚本（含生成的 cron 版） | 先判过期、pid 需为数字、等待有硬上限、拆开 EXIT 与 INT/TERM（后者 `exit 1`）、rm 失败退避 |
| cron 自动更新把 `config.json` 降权为 0644 | `debian/auto_update.sh` 生成的 `/etc/sing-box/update-singbox.sh` | 与交互路径一致 0640（组缺失回落 root，仍不可被本地用户读取） |
| 硬依赖 `sing-box` 组，缺失时客户端完全无法配置 | `manual_input.sh`、`update_config.sh`、`install_singbox.sh`、`commands.sh` | 组缺失时回落 root（保持 0640）并提示；安装时显式 `groupadd` |
| `zipinfo` 失败时压缩包校验“空转通过”（解压炸弹上限被绕过） | 两平台 `update_ui.sh`（含生成的 cron 版） | 检查工具退出码、要求 `count > 0`、从落盘输出读取大小 |
| `confirm_yes` 在 EOF 时 100% CPU 死循环 | 两个 `menu.sh` | `read … || return 1` |
| 备份 `cp -a` 失败与“原本不存在”不可区分 → 回滚删掉健康脚本 | 两个 `menu.sh` | 只回滚确实备份成功的条目；备份失败即中止更新 |
| 首个 `mktemp` 无保护 → 空变量把脚本写到 `/` | 两个 `menu.sh` | 两个 `mktemp` 都检查返回值 |
| `exec sudo` 之前创建临时目录会泄漏 | `update_scripts.sh`、`check_update.sh`、`openwrt/manual_update.sh`、`sbshall.sh` | 先提权再建临时文件；`sbshall.sh` 在 exec 前显式清理 |
| 4 个客户端模板仍走第三方代理 + 可变分支规则集 | `config_template/*.json` | 去掉 `gh-proxy.com`/`ghfast.top` 前缀、面板地址固定 commit、删除未被引用的第三方规则集 |
| Debian UI 安装缺少 chown 失败回滚（与 OpenWrt 不对称） | `debian/update_ui.sh` | 对齐 OpenWrt：失败时恢复旧备份 |

发布流程补充：更新源固定为 **main**，`BASE_REF`/`RELEASE_REF` 固定指针机制已经移除；
CI 的 `Verify update source is main` 步骤与 `tests/suites/06_misc.sh`、`tests/suites/08_archive_fallback.sh`
都会验证 5 个入口脚本不含 `BASE_REF`/`RELEASE_REF`/`resolve_release_ref`，并且确实从 `main` 下载
—— 2026-09-11 的事故（引用的分支被删除后 404 无人发现）就是这次改动的原因。


## 第三轮：真机回归（ImmortalWrt 的 busybox 没有 install）

用户在 ImmortalWrt 上执行一键引导，第一步就中止：

```text
系统为 OpenWrt。
/dev/fd/64: line 57: install: command not found
```

busybox 没有 `install` applet，而本仓库在两个平台上都用 GNU `install -d/-o/-g/-m`
（建目录、落文件，并同时设置权限与所有者）。这行是**既有**代码，前两轮的 CI 都抓不到它：
测试镜像装了 `coreutils`，`install` 一直存在。

修复：OpenWrt 路径的每个脚本内联一个兜底 —— 仅当 `command -v install` 失败时定义
`install()` 函数（用 `mkdir -p` + `chmod`、`cp -f` + `chmod`、`chown` 实现 `-d/-m/-o/-g`
子集）。系统上存在真正的 `install` 时这段完全不生效，因此 Debian 路径零影响。覆盖：`sbshall.sh`（一键引导）与
`openwrt/` 下 9 个脚本，外加 `openwrt/auto_update.sh` 用 heredoc 生成给 cron 的那一份
（cron 里失败会静默不更新配置，比交互路径更隐蔽）。

回归测试：`tests/suites/07_no_install.sh` 构造一个"PATH 里包含全部可执行文件、唯独没有
`install`"的符号链接目录，然后断言 (a) 所有依赖 `install` 的 OpenWrt 脚本都自带兜底（含
heredoc 生成的那份），(b) `set_defaults.sh` 在该环境下成功且 `defaults.conf` 为 0600、
`/etc/sing-box` 为 0755，(c) 生成的 cron 更新脚本成功并把配置写成 0600，(d) 兜底自身在
`set -Eeuo pipefail` 下的语义。

兜底与 `set -Eeuo pipefail` 的关系（写这个兜底时自己踩到的坑）：权限行必须写成
`[ -z "$m" ] || { chmod … || return 1; }`。若写成 `[ -n "$m" ] && chmod …`，chmod/chown
失败时失败的是 AND 列表的**最后一个**命令，errexit 会直接终止整个脚本（函数末尾的
`return 0` 根本执行不到），调用方的 `if ! install …; then restore; fi` 回滚也没机会运行。
现在的语义是：chmod 失败 → 返回非 0（fail-closed，凭据文件绝不能悄悄留在 0644）；
chown 失败 → 显式容忍（所有权不构成安全边界，且 vfat/extroot 等文件系统上必然失败）。
测试用"不存在的属主"和"非法模式"分别触发这两条路径。
