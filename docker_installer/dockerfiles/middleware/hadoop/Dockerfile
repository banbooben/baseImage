ARG REGISTRY=registry.cn-hangzhou.aliyuncs.com
ARG NAMESPACE=sarmn
FROM ${REGISTRY}/${NAMESPACE}/language:noble-openjdk.11 as java
FROM ${REGISTRY}/${NAMESPACE}/base:noble as builder

COPY ./docker_installer/installer/common.sh /deployment/scripts/common.sh
COPY ./docker_installer/installer/middleware/hadoop/install_hadoop.sh /tmp/install_hadoop.sh
RUN /bin/bash /tmp/install_hadoop.sh

FROM ${REGISTRY}/${NAMESPACE}/base:noble
COPY --from=java                                /deployment/openjdk     /deployment/openjdk
COPY --from=java                                /etc/environment        /etc/environments/env-java
COPY --from=builder     --chown=hadoop:hadoop   /deployment/hadoop      /deployment/hadoop
COPY --from=builder                             /etc/environment        /etc/environments/env-hadoop
COPY --from=builder /etc/s6-overlay/s6-rc.d/hadoop /etc/s6-overlay/s6-rc.d/hadoop
COPY --from=builder /etc/s6-overlay/s6-rc.d/user/contents.d/hadoop /etc/s6-overlay/s6-rc.d/user/contents.d/hadoop
COPY --from=builder /etc/cont-env.d/HADOOP_VERSION /etc/cont-env.d/HADOOP_VERSION
COPY --from=builder /etc/cont-env.d/HADOOP_SERIES /etc/cont-env.d/HADOOP_SERIES

ENV JAVA_HOME=/deployment/openjdk \
    HADOOP_HOME=/deployment/hadoop \
    PATH=/deployment/hadoop/bin:/deployment/hadoop/sbin:/deployment/openjdk/bin:$PATH \
    HADOOP_SERIES=3.4 \
    JAVA_VERSION=11

RUN set -e ;\
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/sshd ;\
    /bin/bash -c "source /deployment/scripts/common.sh && merge_and_save_env"

ENTRYPOINT ["/init"]
