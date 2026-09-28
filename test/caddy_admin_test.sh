#!/usr/bin/env bash
# Behavioural test for moving Caddy's admin API off TCP, against a REAL Caddy.
# Starts a Caddy the way a box that predates the socket runs it (admin on TCP
# loopback), runs homeportd's own migration, and checks what Caddy then does:
# TCP admin gone, socket private, reloads still work over it, and a restart
# after an unclean exit (stale socket file) still comes up.
#
# Needs caddy on PATH; skips without it unless REQUIRE_CADDY=1 (CI sets it).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v caddy >/dev/null; then
  [[ ${REQUIRE_CADDY:-} == 1 ]] && { echo "caddy not found (REQUIRE_CADDY=1)"; exit 1; }
  echo "skip: caddy not installed"; exit 0
fi

work=$(mktemp -d)
cleanup() {
  [[ -n ${caddy_pid:-} ]] && kill "$caddy_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

awk "/<<'HOMEPORTD_SCRIPT'/{f=1;next} /^HOMEPORTD_SCRIPT\$/{f=0} f" bootstrap/bootstrap.sh > "$work/homeportd"
# shellcheck disable=SC1091
source "$work/homeportd"
CADDY_DIR=$work/homeport.d
CADDYFILE=$work/Caddyfile
CADDY_GLOBALS_FRAG=$CADDY_DIR/00-globals.caddy
CADDY_GLOBALS_STATE=$work/caddy-globals
CADDY_ENV_FILE=$work/caddy.env
mkdir -p "$CADDY_DIR" "$work/home"; chmod 750 "$work/home"
CADDY_ADMIN_SOCK=$work/home/admin.sock
LEGACY_PORT=${LEGACY_PORT:-23019} SITE_PORT=${SITE_PORT:-18590}
CADDY_LEGACY_ADMIN=localhost:$LEGACY_PORT

printf 'import %s/*.caddy\n' "$CADDY_DIR" > "$CADDYFILE"
printf 'http://:%s {\n\trespond "v1"\n}\n' "$SITE_PORT" > "$CADDY_DIR/site.caddy"
# the legacy box: no homeport globals, admin on Caddy's default TCP listener
printf '{\n\tadmin %s\n}\n' "$CADDY_LEGACY_ADMIN" > "$CADDY_GLOBALS_FRAG"

fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

start() {
  caddy run --config "$CADDYFILE" --adapter caddyfile >>"$work/caddy.log" 2>&1 & caddy_pid=$!
  local i
  for i in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$SITE_PORT/" && return 0; sleep 0.1; done
  echo "caddy did not start:"; tail -5 "$work/caddy.log"; exit 1
}

start
[[ $(curl -s -o /dev/null -w '%{http_code}' "http://$CADDY_LEGACY_ADMIN/config/") == 200 ]] \
  && ok "before: admin answers on TCP (the hole)" || fail "before: expected TCP admin"

# the legacy fragment isn't homeport's — make it look like a pre-socket box's
# (no globals fragment at all) while the running Caddy still has TCP admin
rm -f "$CADDY_GLOBALS_FRAG"
ensure_caddy_admin_socket
sleep 0.5

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$CADDY_LEGACY_ADMIN/config/" || true)
[[ $code == 000 ]] && ok "after: TCP admin gone" || fail "after: TCP admin still answers ($code)"
[[ -S $CADDY_ADMIN_SOCK ]] && ok "after: socket exists" || fail "after: no socket at $CADDY_ADMIN_SOCK"
mode=$(stat -c '%a' "$CADDY_ADMIN_SOCK" 2>/dev/null || stat -f '%Lp' "$CADDY_ADMIN_SOCK")
[[ $mode == 600 ]] && ok "after: socket mode 600" || fail "after: socket mode $mode"
[[ $(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$CADDY_ADMIN_SOCK" http://localhost/config/) == 200 ]] \
  && ok "after: owner reaches admin over the socket" || fail "after: socket admin unreachable"

# ordinary reloads (what `systemctl reload caddy` runs) now go over the socket
printf 'http://:%s {\n\trespond "v2"\n}\n' "$SITE_PORT" > "$CADDY_DIR/site.caddy"
caddy reload --config "$CADDYFILE" --adapter caddyfile --force >/dev/null 2>&1 \
  && ok "reload over the socket" || fail "reload over the socket failed"
sleep 0.3
[[ $(curl -s "http://127.0.0.1:$SITE_PORT/") == v2 ]] && ok "reload applied" || fail "reload not applied"

# idempotent: a second run is a no-op
before=$(cat "$CADDY_GLOBALS_FRAG")
ensure_caddy_admin_socket
[[ $(cat "$CADDY_GLOBALS_FRAG") == "$before" ]] && ok "second run is a no-op" || fail "second run changed the fragment"

# unclean exit leaves the socket file behind; the next start must still bind
kill -9 "$caddy_pid"; wait "$caddy_pid" 2>/dev/null || true; caddy_pid=""
start
[[ $(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$CADDY_ADMIN_SOCK" http://localhost/config/) == 200 ]] \
  && ok "restart after kill -9 rebinds the socket" || fail "stale socket blocked restart"

# another local user (an app) can't use it — only meaningful as root on Linux
if [[ $(id -u) == 0 ]] && id nobody >/dev/null 2>&1; then
  code=$(su -s /bin/sh nobody -c "curl -s -o /dev/null -w '%{http_code}' --unix-socket '$CADDY_ADMIN_SOCK' http://localhost/config/" || true)
  [[ $code == 000 ]] && ok "another user is refused" || fail "another user reached admin ($code)"
fi

if [[ $fails -gt 0 ]]; then echo "$fails caddy admin test(s) FAILED"; exit 1; fi
echo "all caddy admin tests passed ($(caddy version | awk '{print $1}'))"
