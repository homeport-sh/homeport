#!/bin/sh
# Builds PHP and a FrankenPHP without an app, then records how static-php-cli
# linked it - its xcaddy command and the cgo flags - so frankenphp-embed can
# run just that step for an app.
set -eu
S=/go/src/app/dist/static-php-cli
H=/opt/homeport
mkdir -p "$H/bin" "$GOCACHE" "$GOMODCACHE"
./build-static.sh > /tmp/base.log 2>&1 || { tail -80 /tmp/base.log; exit 1; }
sed 's/\x1b\[[0-9;]*m//g' /tmp/base.log | grep -a '\[EXEC\].*xcaddy build' | sed 's/.*\[EXEC\] *//' | tail -1 > "$H/xcaddy.cmd"
test -s "$H/xcaddy.cmd" || { echo "no xcaddy command in the build's log"; exit 1; }
cd "$S"
./spc spc-config "$PHP_EXTENSIONS" --with-libs="$PHP_EXTENSION_LIBS" --includes 2>/dev/null | tail -1 > "$H/cflags"
# spc-config echoes the library list back as a token of its own
./spc spc-config "$PHP_EXTENSIONS" --with-libs="$PHP_EXTENSION_LIBS" --libs 2>/dev/null | tail -1 | tr ' ' '\n' | grep -v ',' | tr '\n' ' ' > "$H/libs"
test -s "$H/cflags" && test -s "$H/libs"
# PHP itself, for composer and the extension check: the base binary
cp buildroot/bin/frankenphp "$H/frankenphp"
# only what linking needs stays: headers, libraries, the Go toolchain
rm -rf "$S/source" "$S/downloads" "$S/log" /tmp/base.log
# builds run unprivileged: the source (app.tar lands there), the libraries
# (the link writes beside them) and the Go caches must be theirs to write
chmod -R a+rwX /go/src/app "$GOCACHE" "$GOMODCACHE"
