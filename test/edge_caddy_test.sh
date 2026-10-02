#!/usr/bin/env bash
# The edge against a REAL Caddy: one process plays both the edge (the
# *.homeport.test wildcard, an origin certificate, origin auth, the route map)
# and a host behind it (an app's http:// block, open to the edge alone), with
# the host on a private address. Checks what Caddy then does with requests.
#
# Needs root (port 443/80, a private address on lo), caddy, openssl, curl.
# Skips without them unless REQUIRE_CADDY=1 (CI sets it).
set -euo pipefail
cd "$(dirname "$0")/.."

skip() { [[ ${REQUIRE_CADDY:-} == 1 ]] && { echo "$1 (REQUIRE_CADDY=1)"; exit 1; }; echo "skip: $1"; exit 0; }
command -v caddy >/dev/null || skip "caddy not installed"
[[ $(id -u) == 0 ]] || skip "needs root"

work=$(mktemp -d)
HOSTIP=10.99.0.1
cleanup() {
  [[ -n ${caddy_pid:-} ]] && kill "$caddy_pid" 2>/dev/null || true
  ip addr del "$HOSTIP/32" dev lo 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
ip addr add "$HOSTIP/32" dev lo   # the host's private address

awk "/<<'HOMEPORTD_SCRIPT'/{f=1;next} /^HOMEPORTD_SCRIPT\$/{f=0} f" bootstrap/bootstrap.sh > "$work/homeportd"
# shellcheck disable=SC1091
source "$work/homeportd"
set +e
CADDY_DIR=$work/homeport.d; CADDYFILE=$work/Caddyfile; CADDY_ENV_FILE=$work/caddy.env
CADDY_GLOBALS_FRAG=$CADDY_DIR/00-globals.caddy; ORIGIN_AUTH_FRAG=$CADDY_DIR/00-origin-auth.caddy
EDGE_DIR=$work/edge; EDGE_ONLY_FRAG=$CADDY_DIR/00-edge-only.caddy; EDGE_SITE_FRAG=$CADDY_DIR/_edge.caddy
EDGE_FROM_FILE=$work/edge-from
mkdir -p "$CADDY_DIR" "$EDGE_DIR"
APP_PORT=18601

fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
eq()   { if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1: got [$2] want [$3]"; fi; }

# --- the edge's configuration, as edge-cert / edge-install write it
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj "/CN=*.homeport.test" \
  -addext "subjectAltName=DNS:*.homeport.test,DNS:homeport.test" \
  -keyout "$EDGE_DIR/origin.key" -out "$EDGE_DIR/origin.pem" 2>/dev/null
origin_auth_snippet "s3cret" > "$ORIGIN_AUTH_FRAG"
edge_site homeport.test > "$EDGE_SITE_FRAG"
printf 'shop.homeport.test %s\n' "$HOSTIP" > "$work/routes"
edge_route_lines "$work/routes" > "$EDGE_DIR/routes.map"
# --- the host behind it, as edge-from and an app's add write it
printf '%s/32\n' "$HOSTIP" > "$EDGE_FROM_FILE"
edge_only_snippet "$HOSTIP/32" > "$EDGE_ONLY_FRAG"
SANDBOX="" TLS_MODE=edge ALIASES="" HEADERS_B64="" REDIRECT_FROM=""
app_addr() { echo 127.0.0.1; }
write_caddy shop shop.homeport.test "$APP_PORT" plain 1
# one process is both, so it trusts both proxies in front: the visitor's own
# hop (here 127.0.0.1, in production Cloudflare) and the edge
GDNS_PROVIDER="" GECH="" GTRUSTED="127.0.0.1/32 $HOSTIP/32" CADDY_ADMIN_SOCK=$work/admin.sock write_caddy_globals
# the app: says who the visitor was
printf 'http://:%s {\n\trespond "app sees {header.X-Forwarded-For} via {header.X-Forwarded-Proto}"\n}\n' "$APP_PORT" > "$CADDY_DIR/zz-app.caddy"
printf 'import %s/*.caddy\n' "$CADDY_DIR" > "$CADDYFILE"

caddy validate --config "$CADDYFILE" --adapter caddyfile >"$work/validate.log" 2>&1 \
  && ok "the edge and a host behind it are a valid Caddy config" || { fail "caddy validate"; cat "$work/validate.log"; exit 1; }
caddy run --config "$CADDYFILE" --adapter caddyfile >"$work/caddy.log" 2>&1 & caddy_pid=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$APP_PORT/" && break; sleep 0.1; done

edge() { # <host> [curl args…] — a request to the edge, as Cloudflare sends it
  local h=$1; shift
  curl -s -k --max-time 5 --resolve "$h:443:127.0.0.1" "$@" "https://$h/"
}
got=$(edge shop.homeport.test -H 'X-Origin-Auth: s3cret' -H 'X-Forwarded-For: 203.0.113.7')
# each trusted hop appends itself: the visitor comes first
[[ $got == "app sees 203.0.113.7,"*" via https" ]] \
  && ok "a routed name reaches its app, with the visitor's address first and the scheme ($got)" \
  || fail "routed: got [$got]"
eq "an unknown name stops at the edge" \
  "$(edge nope.homeport.test -H 'X-Origin-Auth: s3cret' -w ' %{http_code}')" "No app here 404"
eq "not through our Cloudflare zone: refused" \
  "$(edge shop.homeport.test -o /dev/null -w '%{http_code}' || true)" "000"
eq "the host refuses anyone but the edge" \
  "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -H 'Host: shop.homeport.test' http://127.0.0.1:80/ || true)" "000"

# a new table: shop moves away, so its name stops at the edge
: > "$work/routes"; edge_route_lines "$work/routes" > "$EDGE_DIR/routes.map"
caddy reload --config "$CADDYFILE" --adapter caddyfile --address "unix/$work/admin.sock" >/dev/null 2>&1 \
  && ok "a new route table reloads" || { fail "reload"; tail -5 "$work/caddy.log"; }
eq "…and takes effect" "$(edge shop.homeport.test -H 'X-Origin-Auth: s3cret' -w ' %{http_code}')" "No app here 404"

if [[ $fails -gt 0 ]]; then echo "$fails edge test(s) FAILED"; tail -20 "$work/caddy.log"; exit 1; fi
echo "all edge tests passed ($(caddy version | cut -d' ' -f1))"
