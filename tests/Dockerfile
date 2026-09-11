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

COPY fakebin /opt/fakebin
COPY fakebin-busybox /opt/fakebin-busybox
COPY lib /opt/tests/lib
COPY suites /opt/tests/suites
COPY all.sh /opt/tests/all.sh
COPY rc.common /etc/rc.common
COPY initd /etc/init.d-stubs

RUN chmod 0755 /opt/tests/all.sh /opt/tests/suites/*.sh /opt/fakebin/* /opt/fakebin-busybox/* /etc/rc.common /etc/init.d-stubs/*

WORKDIR /opt/tests
CMD ["/opt/tests/all.sh"]
