# Build args for the PostgreSQL/PGAudit versions. Left unset (no default) so
# every build auto-resolves the latest PG_MAJOR.x minor and latest matching
# PGAudit tag at build time -- minor version bumps (including CVE fixes)
# land automatically on the next build, no Dockerfile edit needed. Pass
# --build-arg to pin an exact version instead, e.g. for a reproducible
# release build:
#   docker build \
#     --build-arg PG_VERSION=14.19 \
#     --build-arg PG_SHA256=<sha> \
#     --build-arg PGAUDIT_VERSION=1.6.3 .
ARG PG_MAJOR=14
ARG PG_VERSION
ARG PG_SHA256
ARG PGAUDIT_VERSION

# Stage 1: Build Stage
FROM alpine:3.22 as builder

# Set working directory
WORKDIR /usr/src/postgresql

# Re-declare to bring the global ARGs into this stage, then bind to ENV so
# they're visible to RUN steps.
ARG PG_MAJOR
ARG PG_VERSION
ARG PG_SHA256
ARG PGAUDIT_VERSION
ENV PG_MAJOR=${PG_MAJOR}
ENV PG_VERSION=${PG_VERSION}
ENV PG_SHA256=${PG_SHA256}
ENV PGAUDIT_VERSION=${PGAUDIT_VERSION}

# Install build dependencies.  Use --no-cache to keep the image size down.
RUN apk add --no-cache --virtual .build-deps \
    bison \
    coreutils \
    dpkg-dev dpkg \
    flex \
    gcc \
    git \
    krb5-dev \
    libc-dev \
    libedit-dev \
    libxml2-dev \
    libxslt-dev \
    linux-headers \
    llvm-dev clang g++ \
    make \
    openldap-dev \
    openssl-dev \
    perl-dev \
    perl-ipc-run \
    perl-utils \
    python3-dev \
    tcl-dev \
    util-linux-dev \
    zlib-dev \
    icu-dev \
    wget

# Download and extract PostgreSQL source. If PG_VERSION wasn't pinned via
# --build-arg, auto-resolve the latest PG_MAJOR.x minor from the official
# source index; PG_SHA256 (if unset) is always fetched fresh from the
# matching official .sha256 file, so the download is still checksum-verified
# even on an auto-resolved version.
RUN set -eux; \
    if [ -z "$PG_VERSION" ]; then \
        PG_VERSION="$(wget -qO- https://ftp.postgresql.org/pub/source/ \
            | grep -oE "href=\"v$PG_MAJOR\.[0-9]+/\"" \
            | sed -E 's/href="v(.*)\/"/\1/' \
            | sort -V | tail -1)"; \
    fi; \
    if [ -z "$PG_SHA256" ]; then \
        PG_SHA256="$(wget -qO- "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2.sha256" \
            | awk '{print $1}')"; \
    fi; \
    : "${PG_VERSION:?could not resolve latest PostgreSQL $PG_MAJOR.x version from ftp.postgresql.org}"; \
    : "${PG_SHA256:?could not resolve PG_SHA256 for PostgreSQL $PG_VERSION}"; \
    echo "resolved PG_VERSION=$PG_VERSION PG_SHA256=$PG_SHA256"; \
    wget -O postgresql.tar.bz2 "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2"; \
    echo "$PG_SHA256 *postgresql.tar.bz2" | sha256sum -c -; \
    mkdir -p /usr/src/postgresql; \
    tar \
        --extract \
        --file postgresql.tar.bz2 \
        --directory /usr/src/postgresql \
        --strip-components 1 \
    ; \
    rm postgresql.tar.bz2; \
    \
    gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"


# Patching pg_config_manual.h
RUN set -eux; \
    awk '$1 == "#define" && $2 == "DEFAULT_PGSOCKET_DIR" && $3 == "\"/tmp\"" { $3 = "\"/var/run/postgresql\""; print; next } { print }' src/include/pg_config_manual.h > src/include/pg_config_manual.h.new; \
    grep '/var/run/postgresql' src/include/pg_config_manual.h.new; \
    mv src/include/pg_config_manual.h.new src/include/pg_config_manual.h;

# Configure, compile, and install PostgreSQL
RUN set -eux; \
    gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" && \
    ./configure \
        --build="$gnuArch" \
        --enable-integer-datetimes \
        --enable-thread-safety \
        --enable-tap-tests \
        --disable-rpath \
        --with-uuid=e2fs \
        --with-gnu-ld \
        --with-pgport=5432 \
        --with-system-tzdata=/usr/share/zoneinfo \
        --prefix=/usr/local \
        --with-includes=/usr/local/include \
        --with-libraries=/usr/local/lib \
        --with-krb5 \
        --with-gssapi \
        --with-ldap \
        --with-tcl \
        --with-perl \
        --with-python \
        --with-openssl \
        --with-libxml \
        --with-libxslt \
        --with-icu \
        --with-llvm && \
    make -j "$(nproc)" world && \
    make install-world && \
    make -C contrib install

# Record runtime dependencies
RUN set -eux && \
    RUN_DEPS="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive /usr/local \
            | tr ',' '\n' \
            | sort -u \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
            | grep -v -e perl -e python -e tcl \
    )" && \
    echo $RUN_DEPS > /usr/local/run_deps_from_build

# install pgaudit. If PGAUDIT_VERSION wasn't pinned via --build-arg,
# auto-resolve the latest stable tag in the release series compatible with
# PG_MAJOR, instead of floating on the REL_${PG_MAJOR}_STABLE branch head, so
# the checked-out commit is a specific, reproducible release. PGAudit tagged
# releases independently of the PostgreSQL major version through the 1.x
# series (1.6.x for PG14, 1.7.x for PG15); starting at PG16 it switched to
# tagging releases with the same number as the PostgreSQL major they support.
RUN set -eux && \
    cd /tmp && \
    git clone https://github.com/pgaudit/pgaudit.git && \
    cd pgaudit && \
    if [ -z "$PGAUDIT_VERSION" ]; then \
        case "$PG_MAJOR" in \
            14) PGAUDIT_SERIES=1.6 ;; \
            15) PGAUDIT_SERIES=1.7 ;; \
            *) PGAUDIT_SERIES="$PG_MAJOR" ;; \
        esac; \
        PGAUDIT_VERSION="$(git tag --list "${PGAUDIT_SERIES}.*" | grep -vE '(beta|rc)[0-9]*$' | sort -V | tail -1)"; \
    fi && \
    : "${PGAUDIT_VERSION:?could not resolve a PGAudit release tag matching PostgreSQL major $PG_MAJOR}" && \
    echo "resolved PGAUDIT_VERSION=$PGAUDIT_VERSION" && \
    git checkout "$PGAUDIT_VERSION" && \
    make install USE_PGXS=1 PG_CONFIG=/usr/local/bin/pg_config && \
    apk del --no-network .build-deps && \
    cd / && \
    rm -rf /tmp/pgaudit


# Stage 2: Runtime Stage
FROM alpine:3.22

# Env Variables
ENV LANG en_US.utf8
ENV PGDATA /var/lib/postgresql/data

# Copy initial config files
COPY ./config/data.sql /docker-entrypoint-initdb.d/data.sql
COPY ./config/postgresql.conf ./config/pg_hba.conf /var/lib/postgresql/conf/

#copy compiled files from builder
COPY --from=builder /usr/local /usr/local

# Copy the entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/

# Install runtime dependencies and patch busybox to fix CVE
RUN apk update \
    && apk add --no-cache --upgrade busybox busybox-binsh ssl_client \
    && apk add --no-cache \
        bash \
        su-exec \
        tzdata \
        zstd \
        icu-data-full \
        krb5-libs \
        libldap \
        libxml2 \
        libxslt \
        icu-libs \
        icu \
        libuuid \
        libedit && \
    RUN_DEPS=$(cat /usr/local/run_deps_from_build) && \
    apk add --no-cache --virtual .postgresql-rundeps $RUN_DEPS && \
    rm /usr/local/run_deps_from_build && \
    # set user and group.  Use numeric IDs for consistency and avoid issues with different name resolution.
    addgroup -g 70 -S postgres && \
    adduser -u 70 -S -D -G postgres -H -h /var/lib/postgresql -s /bin/sh postgres && \
    chown -R postgres:postgres /var/lib/postgresql && \
    # Create directories and set permissions
    mkdir -p -m 2777 /var/run/postgresql && \
    chown -R postgres:postgres /var/run/postgresql && \
    # Create data and backup directory, set permissions to 700 for security
    mkdir -p -m 700 "$PGDATA" && \
    chown -R postgres:postgres "$PGDATA"

# Define the volume
VOLUME /var/lib/postgresql/data

# Set entry point
ENTRYPOINT ["docker-entrypoint.sh"]

# Health check.  Use a more robust health check.
HEALTHCHECK --interval=10s --timeout=5s \
    CMD pg_isready -U postgres || exit 1

# Signal
STOPSIGNAL SIGINT

# Expose port
EXPOSE 5432

# Set default user
USER postgres

# Command.  Removed ssl options from here, those are better handled with environment variables or in the postgresql.conf
CMD ["postgres", "-c", "config_file=/var/lib/postgresql/conf/postgresql.conf", "-c", "hba_file=/var/lib/postgresql/conf/pg_hba.conf"]

