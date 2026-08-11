source /deployment/scripts/common.sh

setEnv(){
  export JAVA_HOME=/deployment/openjdk
  export PATH=${JAVA_HOME}/bin:$PATH
  export LANG=C.UTF-8
  export JDK_VERSION=25
  echo "Using Oracle JDK ${JDK_VERSION} latest update"
  write_cont_env JAVA_VERSION "${JDK_VERSION}"
  write_cont_env OPENJDK_VERSION "${JDK_VERSION}"

}

download_and_install(){
  apt-get update; \
  apt-get install -y --no-install-recommends ca-certificates p11-kit
	arch="$(dpkg --print-architecture)"; \
	case "$arch" in \
		'amd64') \
			downloadUrl="https://download.oracle.com/java/${JDK_VERSION}/archive/jdk-${JDK_VERSION}_linux-x64_bin.tar.gz"; \
			;; \
		'arm64') \
			downloadUrl="https://download.oracle.com/java/${JDK_VERSION}/archive/jdk-${JDK_VERSION}_linux-aarch64_bin.tar.gz"; \
			;; \
		*) echo >&2 "error: unsupported architecture: '$arch'"; exit 1 ;; \
	esac; \
	wget --progress=dot:giga -O openjdk.tgz "$downloadUrl"; \
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
	{ \
		echo '#!/usr/bin/env bash'; \
		echo 'set -Eeuo pipefail'; \
		echo 'trust extract --overwrite --format=java-cacerts --filter=ca-anchors --purpose=server-auth "$JAVA_HOME/lib/security/cacerts"'; \
	} > /etc/ca-certificates/update.d/docker-openjdk; \
	chmod +x /etc/ca-certificates/update.d/docker-openjdk; \
	/etc/ca-certificates/update.d/docker-openjdk; \
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
