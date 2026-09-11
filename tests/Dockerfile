# 行为测试镜像：以 root 运行真实脚本，只用 stub 替换 nft/ip/systemctl/sing-box/curl 等
# 外部依赖，因此测试的是仓库里的真实代码路径（不是改写过的副本）。
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      coreutils \
      curl \
      jq \
      passwd \
      procps \
      unzip \
      util-linux \
      zip \
 && rm -rf /var/lib/apt/lists/*

# 测试 harness 统一以 /opt/tests 为根目录；避免测试脚本和镜像构建脚本使用两套路径。
COPY fakebin /opt/tests/fakebin
COPY fakebin-busybox /opt/tests/fakebin-busybox
COPY lib /opt/tests/lib
COPY suites /opt/tests/suites
COPY all.sh /opt/tests/all.sh
COPY rc.common /etc/rc.common
COPY initd /opt/tests/initd

RUN chmod 0755 /opt/tests/all.sh /opt/tests/suites/*.sh /opt/tests/fakebin/* /opt/tests/fakebin-busybox/* /etc/rc.common /opt/tests/initd/*

WORKDIR /opt/tests
CMD ["/opt/tests/all.sh"]
