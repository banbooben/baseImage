ARG REGISTRY=registry.cn-hangzhou.aliyuncs.com
ARG NAMESPACE=sarmn
FROM ${REGISTRY}/${NAMESPACE}/language:noble-openjdk-11 as java
FROM ${REGISTRY}/${NAMESPACE}/base:noble as builder

COPY ./docker_installer/installer/common.sh /deployment/scripts/common.sh
COPY ./docker_installer/installer/middleware/hive/install_hive.sh /tmp/install_hive.sh
# --secret id=HIVE_DB_PASSWORD,env=HIVE_DB_PASSWORD
RUN --mount=type=secret,id=HIVE_DB_PASSWORD,required=false \
    set -eux; \
    [ -s /run/secrets/HIVE_DB_PASSWORD ] && export HIVE_DB_PASSWORD="$(cat /run/secrets/HIVE_DB_PASSWORD)"; \
    /bin/bash /tmp/install_hive.sh

FROM ${REGISTRY}/${NAMESPACE}/base:noble
COPY --from=java                                    /deployment/openjdk     /deployment/openjdk
COPY --from=java                                    /etc/environment        /etc/environments/env-java
COPY --from=builder     --chown=hadoop:hadoop       /deployment/hive        /deployment/hive
COPY --from=builder                                 /etc/environment        /etc/environments/env-hive
COPY --from=builder /etc/s6-overlay/s6-rc.d/hive /etc/s6-overlay/s6-rc.d/hive
COPY --from=builder /etc/s6-overlay/s6-rc.d/hive-metastore /etc/s6-overlay/s6-rc.d/hive-metastore
COPY --from=builder /etc/s6-overlay/s6-rc.d/user/contents.d/hive /etc/s6-overlay/s6-rc.d/user/contents.d/hive
COPY --from=builder /etc/s6-overlay/s6-rc.d/user/contents.d/hive-metastore /etc/s6-overlay/s6-rc.d/user/contents.d/hive-metastore
COPY --from=builder /etc/cont-env.d/HIVE_VERSION /etc/cont-env.d/HIVE_VERSION
COPY --from=builder /etc/cont-env.d/HIVE_SERIES /etc/cont-env.d/HIVE_SERIES
COPY --from=builder /etc/cont-env.d/HADOOP_VERSION /etc/cont-env.d/HADOOP_VERSION
COPY --from=builder /etc/cont-env.d/HADOOP_SERIES /etc/cont-env.d/HADOOP_SERIES

ENV JAVA_HOME=/deployment/openjdk \
    HIVE_HOME=/deployment/hive \
    PATH=/deployment/hive/bin:/deployment/openjdk/bin:$PATH \
    HIVE_SERIES=4 \
    JAVA_VERSION=11

RUN set -e ;\
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/sshd ;\
    /bin/bash -c "source /deployment/scripts/common.sh && merge_and_save_env"

ENTRYPOINT ["/init"]
