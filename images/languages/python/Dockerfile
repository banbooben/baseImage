ARG REGISTRY=registry.cn-hangzhou.aliyuncs.com
ARG NAMESPACE=sarmn
# OS_TAG     产物标签后缀：base:<OS_TAG> / language:<OS_TAG>-python-<PYTHON_SERIES>[-ft] …
# BASE_IMAGE 上游 base 镜像（桌面链为 base:<OS_TAG>-desktop）。Ubuntu 与 openEuler
#            的差异只在这里，安装脚本靠 /etc/os-release 自行分派（见 images/common.sh）
ARG OS_TAG=noble
ARG BASE_IMAGE=${REGISTRY}/${NAMESPACE}/base:${OS_TAG}
FROM ${BASE_IMAGE} AS builder

# PYTHON_SERIES 必填（如 3.12）；free-threaded 构建（tag 后缀 -ft）加 PYTHON_DISABLE_GIL=true
ARG PYTHON_SERIES
ARG PYTHON_DISABLE_GIL=false
ARG PYTHON_ENABLE_OPTIMIZATIONS
ARG PYTHON_PERF_FLAGS
ARG PYTHON_PIN_VERSION

COPY ./images/common.sh /deployment/scripts/common.sh
COPY ./images/languages/python/install_python.sh /tmp/install_python.sh

RUN set -eux ;\
    /bin/bash /tmp/install_python.sh ;\
    echo 'source /deployment/scripts/common.sh' >> /etc/bash.bashrc

FROM ${BASE_IMAGE}
LABEL authors="sarmn"

ARG PYTHON_SERIES

COPY --from=builder /deployment/software/python /deployment/software/python
COPY --from=builder /etc/cont-env.d/PYTHON_VERSION /etc/cont-env.d/PYTHON_VERSION
COPY --from=builder /etc/cont-env.d/PYTHON_SERIES /etc/cont-env.d/PYTHON_SERIES
ENV PATH="/deployment/software/python/bin:$PATH" \
    PYTHONPATH="/deployment/software/python/lib/python${PYTHON_SERIES}/site-packages" \
    PYTHON_SERIES=${PYTHON_SERIES}

ENTRYPOINT ["/init"]
CMD ["python3"]
