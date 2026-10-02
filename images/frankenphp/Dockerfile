# The FrankenPHP base for hosted PHP builds: PHP compiled once, with the
# standard extension set, so an app's build only embeds it and links (see
# frankenphp-embed). One image per PHP version; rebuilt for a PHP patch
# release, a new FrankenPHP, or a change to the extension set.
#
# Pinned by digest: FrankenPHP's own static builder at the version we ship.
ARG BUILDER=dunglas/frankenphp:static-builder-musl-1.12.7@sha256:808eff18dcadb3839dc4316d8d9f55a1d2097add70d46451740886b961164965
FROM ${BUILDER}

ARG FRANKENPHP_VERSION=1.12.7
ARG PHP_VERSION=8.5.11
# every database driver (an unused one costs a few MB, never a dependency),
# what Laravel and its common packages need, and pcntl for queue workers
ARG PHP_EXTENSIONS=bcmath,ctype,curl,dom,exif,fileinfo,filter,gd,iconv,igbinary,intl,mbstring,mysqli,mysqlnd,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,posix,redis,session,simplexml,sockets,sodium,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zip,zlib,apcu
ARG PHP_EXTENSION_LIBS=libavif,nghttp2,nghttp3,ngtcp2,watcher,brotli
ARG COMPOSER_VERSION=2.10.3
ARG COMPOSER_SHA256=7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6

# the Go caches the base build warms, where an unprivileged build can use them
# Every library from source (no --prefer-pre-built): a prebuilt one can be
# compiled with optional dependencies this build doesn't link (curl with
# libssh2 and zstd, libzip with bzip2 and xz), and can change under us
ENV SPC_OPT_DOWNLOAD_ARGS="--ignore-cache-sources=php-src --retry 5"
ENV GOCACHE=/opt/go/cache GOMODCACHE=/opt/go/mod \
    FRANKENPHP_VERSION=${FRANKENPHP_VERSION} PHP_VERSION=${PHP_VERSION} \
    PHP_EXTENSIONS=${PHP_EXTENSIONS} PHP_EXTENSION_LIBS=${PHP_EXTENSION_LIBS}

WORKDIR /go/src/app
COPY build-base.sh /opt/homeport/build-base.sh
RUN sh /opt/homeport/build-base.sh

ADD --checksum=sha256:${COMPOSER_SHA256} https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar /opt/homeport/composer.phar
COPY php composer frankenphp-embed /opt/homeport/bin/
RUN chmod 755 /opt/homeport/bin/* && chmod 644 /opt/homeport/composer.phar \
 && php -r 'echo PHP_VERSION, " ", count(get_loaded_extensions()), " extensions\n";' \
 && composer --version
ENV PATH=/opt/homeport/bin:${PATH}
