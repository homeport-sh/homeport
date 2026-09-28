#!/usr/bin/env bash
# Behavioural test for origin auth against a REAL Caddy: renders sites with
# homeportd's own writers, serves them, and sends requests with, without and
# with a wrong X-Origin-Auth header. The unit tests check the text we generate;
# this checks what Caddy actually does with it — in particular that a gateway's
# handle_path blocks can't be used to skip the check (Caddy orders handle
# before a site-level abort) and that the app never sees the secret.
#
# Needs caddy and python3 on PATH; skips (exit 0) without caddy unless
# REQUIRE_CADDY=1, which CI sets.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v caddy >/dev/null; then
  [[ ${REQUIRE_CADDY:-} == 1 ]] && { echo "caddy not found (REQUIRE_CADDY=1)"; exit 1; }
  echo "skip: caddy not installed"; exit 0
fi

work=$(mktemp -d)
cleanup() {
  [[ -n ${caddy_pid:-} ]] && kill "$caddy_pid" 2>/dev/null || true
  [[ -n ${echo_pid:-} ]] && kill "$echo_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# homeportd, sourced (main is source-guarded) with its paths pointed at $work
awk "/<<'HOMEPORTD_SCRIPT'/{f=1;next} /^HOMEPORTD_SCRIPT\$/{f=0} f" bootstrap/bootstrap.sh > "$work/homeportd"
# shellcheck disable=SC1091
source "$work/homeportd"
CADDY_DIR=$work/homeport.d HOMEPORT_ETC=$work/etc
ORIGIN_AUTH_FRAG=$CADDY_DIR/00-origin-auth.caddy
mkdir -p "$CADDY_DIR" "$HOMEPORT_ETC"

HTTP_PORT=${HTTP_PORT:-18480} UP_PORT=${UP_PORT:-18481}
SECRET=Zx9_k-3QpL7mN2vR8tY4wE6uI1oA5sD0fG_hJ-kLzXc

# upstream: echoes whether it received X-Origin-Auth, so we can prove Caddy
# stripped it before proxying.
cat > "$work/echo.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("upstream saw-secret=%s path=%s\n" % ("X-Origin-Auth" in self.headers, self.path)).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "$work/echo.py" "$UP_PORT" & echo_pid=$!

# sites: a whole-host proxy (with a redirect alias), a gateway with two
# path-mounted apps, and a static site.
write_caddy site site.test "$UP_PORT" plain 1
REDIRECT_FROM=old.test emit_redirect_from site site.test >> "$CADDY_DIR/site.caddy"
mkdir -p "$HOMEPORT_ETC/ga" "$HOMEPORT_ETC/gb" "$work/static"
printf 'DOMAIN=gw.test\nPATH_PREFIX=/a\nPORT=%s\n' "$UP_PORT" > "$HOMEPORT_ETC/ga/config"
printf 'DOMAIN=gw.test\nPATH_PREFIX=/b\nPORT=%s\n' "$UP_PORT" > "$HOMEPORT_ETC/gb/config"
write_gateway gw.test
echo hello > "$work/static/index.html"
HOMEPORT_ROOT=$work/root; mkdir -p "$HOMEPORT_ROOT/st"; ln -s "$work/static" "$HOMEPORT_ROOT/st/current"
write_caddy_static st st.test ""

cat > "$work/Caddyfile" <<EOF
{
	# production shape (HTTPS on scheme-less addresses), with Caddy's own
	# local CA instead of ACME and nothing installed into the system trust
	local_certs
	skip_install_trust
	storage file_system $work/storage
	http_port $((HTTP_PORT + 10))
	https_port $HTTP_PORT
	admin localhost:0
}
import $CADDY_DIR/*.caddy
EOF

fails=0
check() { # <name> <host> <path> <header|-> <want-substring>
  local name=$1 host=$2 path=$3 hdr=$4 want=$5 got
  local -a h=(--resolve "$host:$HTTP_PORT:127.0.0.1")
  [[ $hdr != - ]] && h+=(-H "X-Origin-Auth: $hdr")
  got=$(curl -sk -o - -w ' [%{http_code}]' "${h[@]}" "https://$host:$HTTP_PORT$path" 2>/dev/null || echo " [conn-dropped]")
  # curl reports 000 when the connection is aborted with no response
  got=${got/\[000\]/[conn-dropped]}
  if [[ $got == *"$want"* ]]; then echo "ok   $name"
  else echo "FAIL $name: got '${got//$'\n'/ }' want *$want*"; fails=$((fails+1)); fi
}

start_caddy() {
  [[ -n ${caddy_pid:-} ]] && { kill "$caddy_pid"; wait "$caddy_pid" 2>/dev/null || true; }
  caddy validate --config "$work/Caddyfile" --adapter caddyfile >/dev/null 2>"$work/validate.err" \
    || { echo "FAIL caddy validate:"; cat "$work/validate.err"; caddy validate --config "$work/Caddyfile" --adapter caddyfile 2>&1 | tail -3; exit 1; }
  caddy run --config "$work/Caddyfile" --adapter caddyfile >"$work/caddy.log" 2>&1 & caddy_pid=$!
  local i
  for i in $(seq 1 50); do
    curl -sk -o /dev/null --resolve "site.test:$HTTP_PORT:127.0.0.1" "https://site.test:$HTTP_PORT/" -H "X-Origin-Auth: $SECRET" && return 0
    sleep 0.1
  done
  echo "caddy did not start:"; cat "$work/caddy.log"; exit 1
}

# --- off: everything is served, and the header is still stripped -----------
origin_auth_snippet "" > "$ORIGIN_AUTH_FRAG"
start_caddy
check "off: site served"                site.test /    -       "[200]"
check "off: header stripped anyway"     site.test /    "$SECRET" "saw-secret=False"
check "off: gateway served"             gw.test   /a/x -       "path=/x"

# --- on ---------------------------------------------------------------------
origin_auth_snippet "$SECRET" > "$ORIGIN_AUTH_FRAG"
start_caddy
check "on: site, right secret"          site.test /     "$SECRET" "[200]"
check "on: app never sees the secret"   site.test /     "$SECRET" "saw-secret=False"
check "on: site, no header"             site.test /     -         "[conn-dropped]"
check "on: site, wrong secret"          site.test /     "nope"    "[conn-dropped]"
check "on: redirect alias, no header"   old.test  /     -         "[conn-dropped]"
check "on: redirect alias, right"       old.test  /     "$SECRET" "[301]"
check "on: gateway /a, right"           gw.test   /a/x  "$SECRET" "path=/x"
check "on: gateway /a, no header"       gw.test   /a/x  -         "[conn-dropped]"
check "on: gateway /b, no header"       gw.test   /b/y  -         "[conn-dropped]"
check "on: gateway fallback, no header" gw.test   /zzz  -         "[conn-dropped]"
check "on: gateway fallback, right"     gw.test   /zzz  "$SECRET" "[404]"
check "on: static, right"               st.test   /     "$SECRET" "hello"
check "on: static, no header"           st.test   /     -         "[conn-dropped]"

# --- rotation overlap: both values accepted, anything else still dropped ------
NEW=Qq1_w-2ErT3yU4iO5pA6sD7fG8hJ9kL0zX1cV2bN3m
origin_auth_snippet "$NEW" "$SECRET" > "$ORIGIN_AUTH_FRAG"
start_caddy
check "overlap: new value"              site.test /     "$NEW"    "[200]"
check "overlap: previous value"         site.test /     "$SECRET" "[200]"
check "overlap: gateway, previous"      gw.test   /a/x  "$SECRET" "path=/x"
check "overlap: no header"              site.test /     -         "[conn-dropped]"
check "overlap: wrong value"            site.test /     "nope"    "[conn-dropped]"
check "overlap: new never reaches app"  site.test /     "$NEW"    "saw-secret=False"

if [[ $fails -gt 0 ]]; then echo "$fails caddy origin-auth test(s) FAILED"; exit 1; fi
echo "all caddy origin-auth tests passed ($(caddy version | awk '{print $1}'))"
