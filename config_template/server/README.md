# config_template/server/config.json 是什么？

**这是一个字段参考样例，不是可直接部署的配置。**

历史版本把它作为服务端初始化的默认下载配置，而它带有固定的、已经在公开仓库里
暴露的凭据（Shadowsocks 密码、VLESS UUID、REALITY 私钥、hysteria2 密码）以及某个
特定域名的证书路径。照抄部署等于使用公开凭据，并且证书路径几乎必然不存在。

## 请改用随机生成

```
菜单 → 服务端 → 6. 更新服务端配置文件 → 直接回车
```

或直接运行 `/etc/sing-box/scripts/gen_server_config.sh`。它会：

- 用 `sing-box generate` 在本机生成 SS 密码、VLESS UUID、REALITY 密钥对、short_id、
  hysteria2 密码；
- 只在你确认时才写入 hysteria2 入站，并要求证书文件真实存在；
- 先 `sing-box check` 校验，再备份旧配置并原子替换，最后打印客户端需要的参数。

本样例文件保留了 `REPLACE_ME_*` 占位符，因此 `sing-box check` 不会通过——这是刻意的，
避免有人误以为可以直接使用。

## 证书

`setup.sh`（菜单 → 9. 证书申请）会把证书安装到 `/etc/ssl/<域名>/`。如果启用 hysteria2，
请把 `certificate_path` / `key_path` 指向该目录下的文件。
