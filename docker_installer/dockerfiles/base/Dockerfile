ARG REGISTRY=registry.cn-hangzhou.aliyuncs.com
ARG NAMESPACE=sarmn
FROM ${REGISTRY}/${NAMESPACE}/ubuntu:noble
LABEL authors="sarmn"

# ENV PATH=/deployment/bin:$PATH
ENV LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8
COPY ./docker_installer/installer/common.sh /deployment/scripts/common.sh
COPY ./docker_installer/installer/base/install_base.sh /tmp/install_base.sh
# 密码通过 BuildKit secret 注入（不进 layer / history）：
#   --secret id=ROOT_PASSWORD,env=ROOT_PASSWORD
#   --secret id=SARMN_PASSWORD,env=SARMN_PASSWORD
RUN --mount=type=secret,id=ROOT_PASSWORD,required=false \
    --mount=type=secret,id=SARMN_PASSWORD,required=false \
    set -eux; \
    [ -s /run/secrets/ROOT_PASSWORD ] && export ROOT_PASSWORD="$(cat /run/secrets/ROOT_PASSWORD)"; \
    [ -s /run/secrets/SARMN_PASSWORD ] && export SARMN_PASSWORD="$(cat /run/secrets/SARMN_PASSWORD)"; \
    /bin/bash /tmp/install_base.sh; \
    sed -i '/^ROOT_PASSWORD=/d' /etc/environment 2>/dev/null; \
    sed -i '/^SARMN_PASSWORD=/d' /etc/environment 2>/dev/null; \
    echo 'source /deployment/scripts/common.sh' >> /etc/bash.bashrc

ENTRYPOINT ["/init"]
