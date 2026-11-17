ARG REGISTRY=registry.cn-hangzhou.aliyuncs.com
ARG NAMESPACE=sarmn
# OS_TAG        产物标签后缀：base:<OS_TAG>
# BASE_OS_IMAGE 上游发行版基础镜像。Ubuntu 与 openEuler 的区别只在这里，
#               安装脚本靠 /etc/os-release 自行分派（见 installer/common.sh）
ARG OS_TAG=noble
ARG BASE_OS_IMAGE=${REGISTRY}/${NAMESPACE}/ubuntu:noble
# BASE_PROFILE full（默认，含编译工具链）/ runtime（仅运行时依赖，产物标签
# 约定为 base:<OS_TAG>-runtime，由语言/中间件镜像的 final 阶段复用）
ARG BASE_PROFILE=full
FROM ${BASE_OS_IMAGE}
LABEL authors="sarmn"

# 前置 FROM 之前的 ARG 不会自动进入构建阶段，需在此重新声明才能被 RUN 使用
ARG BASE_PROFILE=full

# ENV PATH=/deployment/bin:$PATH
ENV LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8
COPY ./images/common.sh /deployment/scripts/common.sh
COPY ./images/base/install_base.sh /tmp/install_base.sh
# 构建期不注入、不设置任何密码：root 与业务用户均无密码，SSH 仅密钥登录
RUN set -eux; \
    export BASE_PROFILE="${BASE_PROFILE}"; \
    /bin/bash /tmp/install_base.sh; \
    echo 'source /deployment/scripts/common.sh' >> /etc/bash.bashrc

ENTRYPOINT ["/init"]
