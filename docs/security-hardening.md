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
| P2-8 | `systemd-analyze verify <drop-in 文件>` 在部分 systemd 版本上直接失败并中止安装 | 改为校验父 unit `sing-box.service`，失败仅告警；CI 的 `actions/checkout` 固定到存在的 v4 | `suites/06` |

## 发布流程（固定发布提交）

脚本自更新与一键引导都通过 `BASE_REF` / `RELEASE_REF` 指向一个**不可变的提交**，
而不是分支名：

```
sbshell.sh                RELEASE_REF
debian/menu.sh            BASE_REF
debian/update_scripts.sh  BASE_REF
openwrt/menu.sh           BASE_REF
openwrt/update_scripts.sh BASE_REF
README.md                 模板地址
```

发布新版本时：

1. 在 `main` 上完成并评审改动（CI 会跑语法检查 + 容器化行为测试）；
2. 取该提交的 40 位 SHA：`git rev-parse HEAD`；
3. 把上面这些位置的引用改成这个 SHA，作为新的“发布提交”；
4. 用户重新执行 README 里的一键引导即可拿到新版本；已安装的机器会稳定停留在它被固定
   的那个提交上，直到再次引导。

为什么不用分支名：分支可被移动，任何人拿到写权限（或账号被入侵）都能替换所有脚本内容，
而脚本只做 `bash -n`；固定 SHA 让内容由哈希确定，配合 HTTPS 即可获得完整性保证。
