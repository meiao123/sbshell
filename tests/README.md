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
| `fakebin/` | `nft` `ip` `systemctl` `sing-box` `curl` `sysctl` `ss` `pidof` `opkg` `logread` `ufw` `sshd` 等 stub |
| `fakebin-busybox/` | 模拟 busybox `grep`（不支持 `-P`），用于 OpenWrt 兼容性测试 |
| `rc.common` / `initd/` | 极简 `/etc/rc.common` 与 OpenWrt 风格 init 脚本 |
| `suites/` | 6 个行为测试套件 |

状态都保存在 `$SBSHELL_STUB_STATE`（默认 `/tmp/sbshell-stub-state`），断言直接检查
nft 表、ip rule/route、state 文件、锁目录、cron 文件等可观测结果。

## 套件与审计项的对应关系

| 套件 | 覆盖的审计项 |
| --- | --- |
| `01_debian_menu_flow.sh` | P0-1（RETURN trap 使菜单中止） |
| `02_mode_state.sh` | P1-3.1 TProxy/TUN 对称清理、P1-3.4 fwmark 精确匹配、P1-3.5 快照恢复、P2-7 TUN 表收窄、回滚与外来表拒绝 |
| `03_locks.sh` | P0-3 锁不释放、P2-18 锁/临时文件清理、debian flock 并发 |
| `04_config_update.sh` | P1-3.2 空后端地址、P1-3.3 参数语义、P2-15 订阅校验、P2-1 服务端凭据本地生成、配置更新原子性 |
| `05_openwrt.sh` | P0-4 开机防火墙恢复、P1-3.6 busybox grep、P1-3.7 initialize 失败传播、P2-13 kmod-tun |
| `06_misc.sh` | P0-2 cpuinfo flags、P1-3.8 环境/优化/延迟测试、P2-6 ufw 端口、P2-4 固定发布引用 |

## 本地开发

在 Linux 上快速迭代：

```sh
sudo tests/run.sh --local
```

只想跑某个套件：

```sh
sudo env SBSHELL_SRC="$PWD" SBSHELL_TEST_ROOT="$PWD/tests" \
  PATH="$PWD/tests/fakebin:$PATH" bash tests/suites/02_mode_state.sh
```

注意：`--local` 会写入 `/etc/sing-box`、`/tmp/sbshell-*`，请在一次性环境里跑。
