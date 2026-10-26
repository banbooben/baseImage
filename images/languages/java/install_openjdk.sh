source /deployment/scripts/common.sh

setEnv(){
  export JAVA_HOME=/deployment/software/openjdk
  export PATH=${JAVA_HOME}/bin:$PATH
  export LANG=C.UTF-8
  export JDK_VERSION="${JDK_VERSION:?JDK_VERSION is required (e.g. 21)}"
  # 解析该主版本最新 update（Adoptium 风格 21.0.5+9）；JAVA_PIN_VERSION 可整体钉住。
  # 解析失败不致命——下载阶段回退该主版本的 GA 归档
  JAVA_UPDATE_VERSION="$(resolve_openjdk_latest_version "$JDK_VERSION")" || JAVA_UPDATE_VERSION=""
  export JAVA_UPDATE_VERSION
  echo "Using Oracle JDK ${JAVA_UPDATE_VERSION:-$JDK_VERSION (GA)} (major ${JDK_VERSION})"
  write_cont_env JAVA_VERSION "${JAVA_UPDATE_VERSION:-$JDK_VERSION}"
  write_cont_env OPENJDK_VERSION "${JAVA_UPDATE_VERSION:-$JDK_VERSION}"

}

download_and_install(){
  pkg_update; \
  pkg_install ca-certificates p11-kit
	arch="$(deb_arch)"; \
	case "$arch" in \
		'amd64') \
			oracleArch=x64; \
			;; \
		'arm64') \
			oracleArch=aarch64; \
			;; \
		*) echo >&2 "error: unsupported architecture: '$arch'"; exit 1 ;; \
	esac; \
	# Adoptium 风格版本（21.0.5+9）剥离 +build 后对应 Oracle 归档名（jdk-21.0.5_...）。
	# Oracle 归档的 update 包上架可能晚于 Adoptium 发布，下载失败时回退该主版本的 GA 包
	oracleVersion="${JAVA_UPDATE_VERSION%+*}"; \
	if [ -n "$oracleVersion" ]; then \
		downloadUrl="https://download.oracle.com/java/${JDK_VERSION}/archive/jdk-${oracleVersion}_linux-${oracleArch}_bin.tar.gz"; \
	else \
		downloadUrl="https://download.oracle.com/java/${JDK_VERSION}/archive/jdk-${JDK_VERSION}_linux-${oracleArch}_bin.tar.gz"; \
	fi; \
	if ! wget --progress=dot:giga -O openjdk.tgz "$downloadUrl"; then \
		echo "update archive unavailable, falling back to GA jdk-${JDK_VERSION}"; \
		wget --progress=dot:giga -O openjdk.tgz "https://download.oracle.com/java/${JDK_VERSION}/archive/jdk-${JDK_VERSION}_linux-${oracleArch}_bin.tar.gz" || return 1; \
	fi; \
	\
	mkdir -p "$JAVA_HOME"; \
	tar --extract \
		--file openjdk.tgz \
		--directory "$JAVA_HOME" \
		--strip-components 1 \
		--no-same-owner \
	; \
	rm openjdk.tgz*; \
	\
	sync_java_cacerts '$JAVA_HOME/lib/security/cacerts'; \
	\
	find "$JAVA_HOME/lib" -name '*.so' -exec dirname '{}' ';' | sort -u > /etc/ld.so.conf.d/docker-openjdk.conf; \
	ldconfig; \
	\
	java -Xshare:dump; \
	\
	fileEncoding="$(echo 'System.out.println(System.getProperty("file.encoding"))' | jshell -s -)"; [ "$fileEncoding" = 'UTF-8' ]; rm -rf ~/.java; \
	javac --version; \
	java --version
}


clear_folder(){
  return 0
}

autoExecuteFunc setEnv download_and_install clear_folder
