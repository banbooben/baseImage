ARG REGISTRY=registry.cn-hangzhou.aliyuncs.com
ARG NAMESPACE=sarmn
# OS_TAG 产物标签后缀：本层与上游各层（base / language / software / middleware）
#        的标签统一由它派生，例如 base:<OS_TAG>-desktop、language:<OS_TAG>-python-3.12
ARG OS_TAG=noble
# PYTHON_SERIES 必填（如 3.12）：上游 language 镜像与 python/pip 链接名都由它派生
ARG PYTHON_SERIES

FROM ${REGISTRY}/${NAMESPACE}/software:${OS_TAG}-code-server AS codeserver
FROM ${REGISTRY}/${NAMESPACE}/language:${OS_TAG}-python-${PYTHON_SERIES} AS python


FROM ${REGISTRY}/${NAMESPACE}/base:${OS_TAG}-desktop

LABEL authors="sarmn"

ARG PYTHON_SERIES
ARG UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
ENV UV_DEFAULT_INDEX=${UV_DEFAULT_INDEX}
ENV UV_LINK_MODE=copy

ARG DBEAVER_PIN_VERSION
# 驱动预取：默认全部常用库；DBEAVER_DRIVER_IDS 传逗号分隔的 driver id 可裁剪
ARG DBEAVER_DRIVER_IDS
ARG MAVEN_CENTRAL_PRIMARY
ARG MAVEN_CENTRAL_FALLBACK
ARG WPS_PIN_VERSION
ARG WPS_DEB_URL
# openEuler 侧用 rpm；WPS_PKG_URL 是两者通用的覆盖项，优先级最高
ARG WPS_RPM_URL
ARG WPS_PKG_URL
ARG VSCODE_PIN_VERSION
# Apifox 官方只提供 -latest 包；需要钉版本时指向自建镜像的 zip。
# 默认下载源是阿里云 OSS CDN，FALLBACK 为官方站点（部分地区会返回下载验证页）。
ARG APIFOX_DOWNLOAD_URL
ARG APIFOX_DOWNLOAD_URL_FALLBACK

# install chrome、 dbeaver、wps、vscode、apifox
COPY ./images/software/desktop/install_chrome.sh /tmp/install_chrome.sh
COPY ./images/software/desktop/install_dbeaver.sh /tmp/install_dbeaver.sh
COPY ./images/software/desktop/dbeaver_prefetch.py /tmp/dbeaver_prefetch.py
COPY ./images/software/desktop/install_wps.sh /tmp/install_wps.sh
COPY ./images/software/desktop/install_vscode.sh /tmp/install_vscode.sh
COPY ./images/software/desktop/install_apifox.sh /tmp/install_apifox.sh

RUN set -eux; \
    /bin/bash /tmp/install_chrome.sh; \
    /bin/bash /tmp/install_wps.sh; \
    /bin/bash /tmp/install_vscode.sh; \
    /bin/bash /tmp/install_apifox.sh; \
    ldconfig;

# DBeaver 单独一层：DBEAVER_CACHE_BUST 变化（CI 传 run_id）只重建驱动预取，
# 不必连带重下 chrome/WPS/VS Code/Apifox
ARG DBEAVER_CACHE_BUST
RUN set -eux; \
    echo "dbeaver driver cache bust: ${DBEAVER_CACHE_BUST}"; \
    /bin/bash /tmp/install_dbeaver.sh; \
    ldconfig

# 统一 ENV（避免分散定义导致 PATH/DISPLAY 互相覆盖）
ENV CHROME_HOME=/deployment/software/chrome \
    CHROME_DATA=/deployment/software/chrome/data \
    CHROME_OPTS="--no-sandbox --disable-gpu --disable-dev-shm-usage" \
    DBEAVER_HOME=/deployment/software/dbeaver \
    DBEAVER_DATA=/deployment/software/dbeaver/data \
    WPS_HOME=/deployment/software/wps \
    VSCODE_HOME=/deployment/software/vscode \
    VSCODE_EXTENSIONS=/deployment/software/vscode/extensions \
    VSCODE_DATA=/deployment/software/vscode/data \
    APIFOX_HOME=/deployment/software/apifox \
    APIFOX_DATA=/deployment/software/apifox/data \
    DISPLAY=:1 \
    PATH=/deployment/software/dbeaver:/deployment/software/code-server/bin:/deployment/bin:$PATH


COPY --from=python /deployment/software/python /deployment/software/python

COPY --from=codeserver /deployment/software/code-server /deployment/software/code-server
COPY --from=codeserver /etc/s6-overlay/s6-rc.d/code-server /etc/s6-overlay/s6-rc.d/code-server
COPY --from=codeserver /etc/s6-overlay/s6-rc.d/user/contents.d/code-server /etc/s6-overlay/s6-rc.d/user/contents.d/code-server

# 启用 sshd（s6-overlay v3 用空文件标记启用）
RUN : > /etc/s6-overlay/s6-rc.d/user/contents.d/sshd; \
    ln -s /deployment/software/code-server/bin/code-server /deployment/bin/code-server; \
    ln -s /deployment/software/python/bin/python${PYTHON_SERIES} /deployment/bin/python3; \
    ln -s /deployment/software/python/bin/pip${PYTHON_SERIES} /deployment/bin/pip3

ENTRYPOINT ["/init"]
