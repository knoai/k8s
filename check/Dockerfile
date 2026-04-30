FROM alpine:3.19

# 安装运行时依赖
RUN apk add --no-cache bash curl jq coreutils gawk ca-certificates openssl

# 安装 kubectl（匹配容器架构）
ARG KUBECTL_VERSION=v1.30.0
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

WORKDIR /opt/k8s-acceptance

# 复制项目文件
COPY run-acceptance.sh entrypoint.sh config.env ./
COPY lib/ ./lib/
COPY checks/ ./checks/
COPY manifests/ ./manifests/

# 创建报告目录并确保可写
RUN mkdir -p report && chmod 777 report && \
    chmod +x run-acceptance.sh entrypoint.sh lib/*.sh checks/*.sh

ENTRYPOINT ["./entrypoint.sh"]
CMD []
