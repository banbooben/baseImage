ARG REGISTRY=registry.cn-hangzhou.aliyuncs.com
ARG NAMESPACE=sarmn
ARG OS_TAG=noble
ARG BASE_IMAGE=${REGISTRY}/${NAMESPACE}/base:${OS_TAG}
FROM ${BASE_IMAGE} AS builder

# JDK_VERSION 必填（主版本号，如 21）；JAVA_PIN_VERSION 可钉住具体 update（如 21.0.5+9）
ARG JDK_VERSION
ARG JAVA_PIN_VERSION

COPY ./images/common.sh /deployment/scripts/common.sh
COPY ./images/languages/java/install_openjdk.sh /tmp/install_java.sh
RUN /bin/bash /tmp/install_java.sh

FROM ${BASE_IMAGE}
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
