ARG REGISTRY=registry.cn-hangzhou.aliyuncs.com
ARG NAMESPACE=sarmn
FROM ${REGISTRY}/${NAMESPACE}/base:noble

COPY ./docker_installer/installer/common.sh /deployment/scripts/common.sh
COPY ./docker_installer/installer/middleware/mariadb/install_mariadb_new.sh /tmp/install_mariadb.sh
COPY ./docker_installer/dockerfiles/middleware/mariadb/mariadb-docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh ;\
    /bin/bash /tmp/install_mariadb.sh ;\
    /bin/bash -c "source /deployment/scripts/common.sh && merge_and_save_env"

ENV PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH \
    MARIADB_SERIES=11.4

ENTRYPOINT ["/init"]
