ARG REGISTRY=registry.cn-hangzhou.aliyuncs.com
ARG NAMESPACE=sarmn
ARG OS_TAG=noble
ARG BASE_IMAGE=${REGISTRY}/${NAMESPACE}/base:${OS_TAG}
# 最终产物只保留运行时依赖；builder 侧仍用 full 档（下载/解包工具齐全）
ARG RUNTIME_IMAGE=${REGISTRY}/${NAMESPACE}/base:${OS_TAG}-runtime
FROM ${BASE_IMAGE} AS builder

# JDK_VERSION 必填（主版本号，如 21）；JAVA_PIN_VERSION 可钉住具体 update（如 21.0.5+9）
ARG JDK_VERSION
ARG JAVA_PIN_VERSION

COPY ./images/common.sh /deployment/scripts/common.sh
COPY ./images/languages/java/install_openjdk.sh /tmp/install_java.sh
RUN /bin/bash /tmp/install_java.sh

FROM ${RUNTIME_IMAGE}
LABEL authors="sarmn"

ARG JDK_VERSION

COPY --from=builder /deployment/software/openjdk /deployment/software/openjdk
COPY --from=builder /etc/cont-env.d/JAVA_VERSION /etc/cont-env.d/JAVA_VERSION
COPY --from=builder /etc/cont-env.d/OPENJDK_VERSION /etc/cont-env.d/OPENJDK_VERSION
COPY --from=builder /etc/environment /etc/environments/env-java
ENV PATH=/deployment/software/openjdk/bin:$PATH \
    JAVA_HOME=/deployment/software/openjdk \
    JAVA_VERSION=${JDK_VERSION}
RUN /bin/bash -c "source /deployment/scripts/common.sh && merge_and_save_env"

ENTRYPOINT ["/init"]
CMD ["jshell"]
