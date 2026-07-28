#!/bin/bash
source /deployment/scripts/common.sh

setEnv(){
  # MariaDB LTS series (major.minor), resolve latest patch for apt package + repo
  export MARIADB_SERIES=11.4
  MARIADB_BASE_VERSION="$(resolve_eol_latest_version mariadb "$MARIADB_SERIES" MARIADB_PIN_VERSION)" || return 1
  export MARIADB_BASE_VERSION
  export MARIADB_VERSION="1:${MARIADB_BASE_VERSION}+maria~ubu2404"
  GOSU_VERSION="$(resolve_github_latest_tag tianon/gosu GOSU_PIN_VERSION)" || return 1
  export GOSU_VERSION
  export GPG_KEYS=177F4010FE56CA3336300305F1656F24C74CD1D8
  export REPOSITORY="http://archive.mariadb.org/mariadb-${MARIADB_BASE_VERSION}/repo/ubuntu/ noble main main/debug"
  echo "Using MariaDB ${MARIADB_BASE_VERSION} (series ${MARIADB_SERIES}), gosu ${GOSU_VERSION}"

}

initS6Config(){
  write_cont_env MARIADB_VERSION "${MARIADB_BASE_VERSION}"
  write_cont_env MARIADB_SERIES "${MARIADB_SERIES}"
  write_cont_env MARIADB_PACKAGE_VERSION "${MARIADB_VERSION}"
  write_cont_env GOSU_VERSION "${GOSU_VERSION}"
  # Official entrypoint is copied into the image as /docker-entrypoint.sh
  register_s6_longrun_cmd mariadb "exec /docker-entrypoint.sh mariadbd"
}

installMariaDB() {

  set -eux; \
  	apt-get update; \
  	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  		ca-certificates \
  		gpg \
  		gpgv \
  		libjemalloc2 \
  		pwgen \
  		tzdata \
  		xz-utils \
  		zstd ; \
  	savedAptMark="$(apt-mark showmanual)"; \
  	apt-get install -y --no-install-recommends \
  		dirmngr \
  		gpg-agent \
  		wget; \
  	rm -rf /var/lib/apt/lists/*; \
  	dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
  	wget -q -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
  	wget -q -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
  	GNUPGHOME="$(mktemp -d)"; \
  	export GNUPGHOME; \
  	gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
  	for key in $GPG_KEYS; do \
  		gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key"; \
  	done; \
  	gpg --batch --export "$GPG_KEYS" > /etc/apt/trusted.gpg.d/mariadb.gpg; \
  	if command -v gpgconf >/dev/null; then \
  		gpgconf --kill all; \
  	fi; \
  	gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
  	gpgconf --kill all; \
  	rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
  	apt-mark auto '.*' > /dev/null; \
  	[ -z "$savedAptMark" ] ||	apt-mark manual $savedAptMark >/dev/null; \
  	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
  	chmod +x /usr/local/bin/gosu; \
  	gosu --version; \
  	gosu nobody true ;\
  	set -e;\
    	echo "deb ${REPOSITORY}" > /etc/apt/sources.list.d/mariadb.list; \
    	{ \
    		echo 'Package: *'; \
    		echo 'Pin: release o=MariaDB'; \
    		echo 'Pin-Priority: 999'; \
    	} > /etc/apt/preferences.d/mariadb ;\
    set -ex; \
      { \
        echo "mariadb-server" mysql-server/root_password password 'unused'; \
        echo "mariadb-server" mysql-server/root_password_again password 'unused'; \
      } | debconf-set-selections; \
      apt-get update; \
    # postinst script creates a datadir, so avoid creating it by faking its existance.
      mkdir -p /var/lib/mysql/mysql ; touch /var/lib/mysql/mysql/user.frm ; \
    # mariadb-backup is installed at the same time so that `mysql-common` is only installed once from just mariadb repos
      apt-get install -y --no-install-recommends mariadb-server="$MARIADB_VERSION" mariadb-backup socat \
      ; \
      rm -rf /var/lib/apt/lists/*; \
    # purge and re-create /var/lib/mysql with appropriate ownership
      rm -rf /var/lib/mysql; \
      mkdir -p /var/lib/mysql /run/mysqld; \
      chown -R mysql:mysql /var/lib/mysql /run/mysqld; \
    # ensure that /run/mysqld (used for socket and lock files) is writable regardless of the UID our mysqld instance ends up having at runtime
      chmod 1777 /run/mysqld; \
    # comment out a few problematic configuration values
      find /etc/mysql/ -name '*.cnf' -print0 \
        | xargs -0 grep -lZE '^(bind-address|log|user\s)' \
        | xargs -rt -0 sed -Ei 's/^(bind-address|log|user\s)/#&/'; \
    # don't reverse lookup hostnames, they are usually another container
      printf "[mariadb]\nhost-cache-size=0\nskip-name-resolve\n" > /etc/mysql/mariadb.conf.d/05-skipcache.cnf; \
    # Issue #327 Correct order of reading directories /etc/mysql/mariadb.conf.d before /etc/mysql/conf.d (mount-point per documentation)
      if [ -L /etc/mysql/my.cnf ]; then \
    # 10.5+
        sed -i -e '/includedir/ {N;s/\(.*\)\n\(.*\)/\n\2\n\1/}' /etc/mysql/mariadb.cnf; \
      fi
}

autoExecuteFunc setEnv installMariaDB initS6Config
