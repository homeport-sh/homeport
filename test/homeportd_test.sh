#!/usr/bin/env bash
# Unit tests for homeportd's pure helper functions. Extracts the embedded
# homeportd from bootstrap/bootstrap.sh and sources it — `main` is source-guarded
# so nothing executes. No root, no systemd, no network: just the pure logic that
# has bitten us before (timeout_secs, replica math, Caddy generation, limits).
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
hd=$(mktemp)
trap 'rm -f "$hd"' EXIT
awk "/<<'HOMEPORTD_SCRIPT'/{f=1;next} /^HOMEPORTD_SCRIPT\$/{f=0} f" "$root/bootstrap/bootstrap.sh" > "$hd"

# shellcheck disable=SC1090
source "$hd"          # defines the helpers; guarded main does not run
set +eu               # some assertions intentionally probe unset/edge inputs

fails=0
eq() { # eq <label> <got> <want>
  if [[ "$2" == "$3" ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: got [%s] want [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}
has() { # has <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: [%s] missing [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}

# --- timeout_secs (the single-line-local bug lived here) ---
eq "timeout_secs 30s"   "$(timeout_secs 30s)"  "30"
eq "timeout_secs 2m"    "$(timeout_secs 2m)"   "120"
eq "timeout_secs 1h"    "$(timeout_secs 1h)"   "3600"
eq "timeout_secs empty" "$(timeout_secs '')"   "30"
eq "timeout_secs junk"  "$(timeout_secs abc)"  "30"

# --- replica_base: each app gets a unique 20-slot block ---
eq "replica_base 8100" "$(replica_base 8100)" "10000"
eq "replica_base 8101" "$(replica_base 8101)" "10020"

# --- gateway_slug ---
eq "gateway_slug" "$(gateway_slug api.example.com)" "api-example-com"

# --- app_upstreams: plain single port vs template replica ports ---
eq "upstreams plain"    "$(app_upstreams 8101 plain 1)"    " 127.0.0.1:8101"
eq "upstreams template" "$(app_upstreams 8101 template 2)" " 127.0.0.1:10021 127.0.0.1:10022"

# --- app_mode (reads REPLICAS / AUTOSCALE_MAX / IDLE) ---
REPLICAS=1 AUTOSCALE_MAX="" IDLE="";  eq "app_mode plain"     "$(app_mode)" "plain"
REPLICAS=3 AUTOSCALE_MAX="" IDLE="";  eq "app_mode replicas"  "$(app_mode)" "template"
REPLICAS=1 AUTOSCALE_MAX=4 IDLE="";   eq "app_mode autoscale" "$(app_mode)" "template"
REPLICAS=1 AUTOSCALE_MAX="" IDLE=1;   eq "app_mode idle"      "$(app_mode)" "idle"
unset REPLICAS AUTOSCALE_MAX IDLE

# --- compute_limits (the 1G->MemoryHigh=0 integer-floor bug lived here) ---
eq "limits none" "$(compute_limits '' '')" ""
lim=$(compute_limits 1G 150%)
has "limits MemoryMax"  "$lim" "MemoryMax=1G"
has "limits CPUQuota"   "$lim" "CPUQuota=150%"
has "limits high bytes" "$lim" "MemoryHigh=966367641"   # not floored to 0G

# --- Caddy fragment generation ---
CADDY_DIR=$(mktemp -d); trap 'rm -f "$hd"; rm -rf "$CADDY_DIR"' EXIT
write_caddy web web.example.com 8101 plain 1
has "write_caddy site"  "$(cat "$CADDY_DIR/web.caddy")" "web.example.com {"
has "write_caddy proxy" "$(cat "$CADDY_DIR/web.caddy")" "reverse_proxy 127.0.0.1:8101"
write_caddy_internal svc 8102 3
has "internal LB addr" "$(cat "$CADDY_DIR/svc.caddy")" "http://127.0.0.1:8102 {"
has "internal LB pol"  "$(cat "$CADDY_DIR/svc.caddy")" "lb_policy least_conn"

# --- user response headers (opt-in; homeport sets NONE by default) ---
if [[ "$(cat "$CADDY_DIR/web.caddy")" == *"header {"* ]]; then
  printf 'FAIL headers: default fragment has a header block\n'; fails=$((fails + 1))
else printf 'ok   headers: none by default\n'; fi
# records are glob<TAB>name<TAB>value; "/*" is a global block, "/dir/*" a matcher
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
HEADERS_B64=$(b64 "$(printf '/*\tX-Frame-Options\tSAMEORIGIN\n/_app/immutable/*\tCache-Control\tpublic, max-age=31536000, immutable\n')")
write_caddy hdr h.example.com 8105 plain 1
hdrcfg=$(cat "$CADDY_DIR/hdr.caddy")
has "headers global block"  "$hdrcfg" "header {"
has "headers global value"  "$hdrcfg" 'X-Frame-Options "SAMEORIGIN"'
has "headers path matcher"  "$hdrcfg" "path /_app/immutable/*"
has "headers path scoped"   "$hdrcfg" 'Cache-Control "public, max-age=31536000, immutable"'
HEADERS_B64=""
# validate_headers is the security gate — accepts a clean header, rejects any
# name/value/glob that could break out of the generated Caddyfile.
if ( validate_headers "$(b64 "$(printf '/*\tX-Frame-Options\tDENY')")" ) 2>/dev/null; then
  printf 'ok   headers: accepts clean\n'; else printf 'FAIL headers: rejected clean\n'; fails=$((fails + 1)); fi
reject_hdr() { # reject_hdr <label> <raw-record>
  if ( validate_headers "$(b64 "$2")" ) 2>/dev/null; then
    printf 'FAIL %s: accepted\n' "$1"; fails=$((fails + 1)); else printf 'ok   %s\n' "$1"; fi
}
reject_hdr "headers reject brace"     "$(printf '/*\tX\ta{b')"
reject_hdr "headers reject quote"     "$(printf '/*\tX\ta"b')"
reject_hdr "headers reject backslash" "$(printf '/*\tX\ta\\b')"
reject_hdr "headers reject bad name"  "$(printf '/*\tBad Name\tv')"
reject_hdr "headers reject bad glob"  "$(printf 'api/*\tX\tv')"
reject_hdr "headers reject dotdot"    "$(printf '/../etc/*\tX\tv')"

# --- bring-your-own TLS cert (opt-in; automatic HTTPS by default) ---
if [[ "$(cat "$CADDY_DIR/web.caddy")" == *"tls "* ]]; then
  printf 'FAIL tls: default fragment has a tls directive\n'; fails=$((fails + 1))
else printf 'ok   tls: auto by default (no tls directive)\n'; fi
TLS_CERT_DIR=$(mktemp -d)   # test cert store
TLS_MODE=manual
# manual but no cert uploaded yet → NO tls directive (a directive pointing at
# missing files would invalidate the whole Caddyfile; also breaks the
# register-then-upload chicken/egg for fresh apps)
write_caddy tlsapp t.example.com 8106 plain 1
if [[ "$(cat "$CADDY_DIR/tlsapp.caddy")" == *"tls $TLS_CERT_DIR"* ]]; then
  printf 'FAIL tls: emitted directive with no cert on disk\n'; fails=$((fails + 1))
else printf 'ok   tls: manual without cert emits nothing\n'; fi
# cert present → directive emitted, for both app shapes
mkdir -p "$TLS_CERT_DIR/tlsapp" "$TLS_CERT_DIR/tlsstat"
touch "$TLS_CERT_DIR/tlsapp/cert.pem" "$TLS_CERT_DIR/tlsstat/cert.pem"
write_caddy tlsapp t.example.com 8106 plain 1
has "tls manual directive" "$(cat "$CADDY_DIR/tlsapp.caddy")" \
  "tls $TLS_CERT_DIR/tlsapp/cert.pem $TLS_CERT_DIR/tlsapp/key.pem"
write_caddy_static tlsstat s.example.com ""
has "tls manual on static" "$(cat "$CADDY_DIR/tlsstat.caddy")" "tls $TLS_CERT_DIR/tlsstat/cert.pem"
# dns mode: default env var derived from provider; override; SDK-env "none"
TLS_MODE="dns:cloudflare" TLS_DNS_ENV=""
write_caddy dnsapp d.example.com 8107 plain 1
has "tls dns default env" "$(cat "$CADDY_DIR/dnsapp.caddy")" "dns cloudflare {env.HOMEPORT_DNS_CLOUDFLARE}"
TLS_DNS_ENV="CF_API_TOKEN"
write_caddy dnsapp d.example.com 8107 plain 1
has "tls dns env override" "$(cat "$CADDY_DIR/dnsapp.caddy")" "dns cloudflare {env.CF_API_TOKEN}"
TLS_DNS_ENV="none"
write_caddy dnsapp d.example.com 8107 plain 1
if [[ "$(cat "$CADDY_DIR/dnsapp.caddy")" == *"{env."* ]]; then
  printf 'FAIL tls dns none still has env placeholder\n'; fails=$((fails + 1))
else printf 'ok   tls dns none emits bare provider\n'; fi
has "tls dns none directive" "$(cat "$CADDY_DIR/dnsapp.caddy")" "dns cloudflare"
eq "dns_default_env dashes" "$(dns_default_env "azure-dns")" "HOMEPORT_DNS_AZURE_DNS"
TLS_MODE="" TLS_DNS_ENV=""
rm -rf "$TLS_CERT_DIR"

# --- multi-domain serving + redirect_from aliases ---
ALIASES="www.m.example.com,m.example.net"
REDIRECT_FROM="old.m.example.com"
write_caddy multi m.example.com 8108 plain 1
mcfg=$(cat "$CADDY_DIR/multi.caddy")
has "multi-domain host line" "$mcfg" "m.example.com, www.m.example.com, m.example.net {"
has "redirect alias block"   "$mcfg" "old.m.example.com {"
has "redirect 301 target"    "$mcfg" 'redir https://m.example.com{uri} permanent'
write_caddy_static multi m.example.com ""
has "static multi-domain hosts" "$(cat "$CADDY_DIR/multi.caddy")" "m.example.com, www.m.example.com, m.example.net {"
ALIASES="" REDIRECT_FROM=""
write_caddy multi m.example.com 8108 plain 1
if [[ "$(cat "$CADDY_DIR/multi.caddy")" == *"redir "* ]]; then
  printf 'FAIL redirect blocks emitted with empty REDIRECT_FROM\n'; fails=$((fails + 1))
else printf 'ok   no redirect blocks when unset\n'; fi

# --- managed Caddy global options (00-globals.caddy generator) ---
CADDY_GLOBALS_FRAG="$CADDY_DIR/00-globals.caddy"
GDNS_PROVIDER=cloudflare GDNS_ENV=HOMEPORT_DNS_CLOUDFLARE GECH=""
write_caddy_globals
g=$(cat "$CADDY_GLOBALS_FRAG")
has "globals dns line"      "$g" "dns cloudflare {env.HOMEPORT_DNS_CLOUDFLARE}"
GECH=ech.example.com
write_caddy_globals
g=$(cat "$CADDY_GLOBALS_FRAG")
has "globals ech line"      "$g" "ech ech.example.com"
# dynamic_dns was removed in v0.3.0 — the generator must never emit it again
if [[ $g == *"dynamic_dns"* ]]; then
  printf 'FAIL globals: dynamic_dns block resurfaced\n'; fails=$((fails + 1))
else printf 'ok   globals: no dynamic_dns block\n'; fi
GDNS_ENV=none
write_caddy_globals
g=$(cat "$CADDY_GLOBALS_FRAG")
has "globals dns sdk-env"   "$g" $'\tdns cloudflare\n'
if [[ $g == *"{env."* ]]; then
  printf 'FAIL globals: env placeholder emitted with GDNS_ENV=none\n'; fails=$((fails + 1))
else printf 'ok   globals: no env placeholder when none\n'; fi
GDNS_PROVIDER="" GDNS_ENV="" GECH=""
write_caddy_globals
if [[ -f $CADDY_GLOBALS_FRAG ]]; then
  printf 'FAIL globals: fragment survives with nothing set\n'; fails=$((fails + 1))
else printf 'ok   globals: fragment removed when empty\n'; fi
# 00-globals must sort before every site fragment so the block lands first
first=$(printf '00-globals.caddy\n00-homeport.caddy\nweb.caddy\n_gw_x.caddy\n' | LC_ALL=C sort | head -1)
eq "globals sorts first" "$first" "00-globals.caddy"

# --- valid_caddy_module: plugin names become URL params + argv — the gate ---
ok_mod()  { valid_caddy_module "$1" && printf 'ok   mod accept %s\n' "$1" || { printf 'FAIL mod accept %s\n' "$1"; fails=$((fails + 1)); }; }
bad_mod() { valid_caddy_module "$1" && { printf 'FAIL mod reject %s\n' "$1"; fails=$((fails + 1)); } || printf 'ok   mod reject %s\n' "$1"; }
ok_mod  "github.com/caddy-dns/cloudflare"
ok_mod  "github.com/mholt/caddy-ratelimit"
ok_mod  "github.com/greenpau/caddy-security/v2"
bad_mod "cloudflare"                                  # no slash — not a repo path
bad_mod "github.com/x/../../../etc"                   # traversal
bad_mod "github.com/x/y&os=windows"                   # URL param smuggling
bad_mod "github.com/x/y z"                            # space → argv smuggling
bad_mod "-flag/inject"                                # leading dash
bad_mod ""                                            # empty

# --- valid_cidr: firewall ranges become ufw argv — the gate ---
ok_cidr()  { valid_cidr "$1" && printf 'ok   cidr accept %s\n' "$1" || { printf 'FAIL cidr accept %s\n' "$1"; fails=$((fails + 1)); }; }
bad_cidr() { valid_cidr "$1" && { printf 'FAIL cidr reject %s\n' "$1"; fails=$((fails + 1)); } || printf 'ok   cidr reject %s\n' "$1"; }
ok_cidr  "103.21.244.0/22"      # a real Cloudflare range
ok_cidr  "192.0.2.1/32"
ok_cidr  "2400:cb00::/32"       # Cloudflare IPv6
ok_cidr  "::1/128"
bad_cidr "103.21.244.0"         # bare IP, no mask
bad_cidr "999.1.1.0/24"         # octet out of range
bad_cidr "10.0.0.0/33"          # mask too big
bad_cidr "2400:cb00::/200"      # v6 mask too big
bad_cidr "10.0.0.0/8; rm -rf /" # argv injection
bad_cidr ""

# --- tls_needs_inbound_acme: which apps the firewall warning should flag ---
# Only HTTP-01 (default/empty mode) needs Let's Encrypt to reach 80/443. manual
# (BYO cert) and dns:* (DNS-01) both work behind a Cloudflare-only firewall, so
# they must NOT be warned about — warning on a dns: app is a false positive.
needs_acme()    { tls_needs_inbound_acme "$1" && printf 'ok   flags http-01 mode %q\n' "$1" || { printf 'FAIL should flag %q\n' "$1"; fails=$((fails + 1)); }; }
no_needs_acme() { tls_needs_inbound_acme "$1" && { printf 'FAIL should NOT flag %q\n' "$1"; fails=$((fails + 1)); } || printf 'ok   exempts %q\n' "$1"; }
needs_acme    ""                 # default automatic HTTPS = HTTP-01
no_needs_acme "manual"           # BYO cert — no ACME at all
no_needs_acme "dns:cloudflare"   # DNS-01 — works behind the firewall
no_needs_acme "dns:route53"

# --- write_gateway merges path apps, longest prefix first ---
# write_gateway uses mapfile (bash 4+); skip on ancient bash (e.g. macOS 3.2).
if ! command -v mapfile >/dev/null 2>&1; then
  printf 'skip write_gateway (needs bash 4+, this is %s)\n' "$BASH_VERSION"
else
HOMEPORT_ETC=$(mktemp -d)
mkdir -p "$HOMEPORT_ETC/geo" "$HOMEPORT_ETC/users"
printf 'DOMAIN=api.example.com\nPATH_PREFIX=/users\nPORT=8103\nREPLICAS=1\n'      > "$HOMEPORT_ETC/users/config"
printf 'DOMAIN=api.example.com\nPATH_PREFIX=/users/admin\nPORT=8104\nREPLICAS=1\n' > "$HOMEPORT_ETC/geo/config"
write_gateway api.example.com
gw=$(cat "$CADDY_DIR/_gw_api-example-com.caddy")
has "gateway host"  "$gw" "api.example.com {"
has "gateway users" "$gw" "handle_path /users/*"
has "gateway admin" "$gw" "handle_path /users/admin/*"
# longest-first: /users/admin must appear before the shorter /users
if [[ $(grep -n 'handle_path /users/admin' <<<"$gw" | cut -d: -f1) -lt $(grep -n 'handle_path /users/\*' <<<"$gw" | head -1 | cut -d: -f1) ]]; then
  printf 'ok   gateway longest-prefix-first\n'
else printf 'FAIL gateway ordering\n%s\n' "$gw"; fails=$((fails + 1)); fi
rm -rf "$HOMEPORT_ETC"
fi

# --- ci_gate_decision: the scoped-CI-key security policy ---
hd=/usr/local/bin/homeportd
gate() { ci_gate_decision "$1" "$2"; }
has "gate: upload own app"      "$(gate web "sudo $hd upload web r1")"        "allow"
has "gate: activate own app"    "$(gate web "sudo $hd activate web r1")"      "allow"
has "gate: env own app"         "$(gate web "sudo $hd env web")"              "allow"
has "gate: version"             "$(gate web "sudo $hd version")"              "allow"
has "gate: no-sudo form"        "$(gate web "$hd status web")"                "allow"
has "gate: deny remove"         "$(gate web "sudo $hd remove web --yes")"     "deny"
has "gate: deny self-update"    "$(gate web "sudo $hd self-update")"          "deny"
has "gate: deny key-add"        "$(gate web "sudo $hd key-add")"              "deny"
has "gate: deny key-rm"         "$(gate web "sudo $hd key-rm x")"             "deny"
has "gate: deny tls-set"        "$(gate web "sudo $hd tls-set web")"          "deny"
has "gate: deny tls-clear"      "$(gate web "sudo $hd tls-clear web")"        "deny"
has "gate: deny caddy-plugin-add"  "$(gate web "sudo $hd caddy-plugin-add x/y")" "deny"
has "gate: deny caddy-plugin-rm"   "$(gate web "sudo $hd caddy-plugin-rm x/y")"  "deny"
has "gate: deny firewall-set"      "$(gate web "sudo $hd firewall-set")"         "deny"
has "gate: deny firewall-clear"    "$(gate web "sudo $hd firewall-clear")"       "deny"
has "gate: deny caddy-env-set"     "$(gate web "sudo $hd caddy-env-set X")"      "deny"
has "gate: deny global-dns"        "$(gate web "sudo $hd global-dns cloudflare")" "deny"
has "gate: deny global-ech"        "$(gate web "sudo $hd global-ech x.com")"      "deny"
has "gate: deny global-ech-rotate" "$(gate web "sudo $hd global-ech-rotate")"    "deny"
has "gate: deny other app"      "$(gate web "sudo $hd activate shop r1")"     "deny"
has "gate: deny env other app"  "$(gate web "sudo $hd env-sync shop")"        "deny"
has "gate: deny arbitrary cmd"  "$(gate web "cat /etc/shadow")"               "deny"
has "gate: deny scp"            "$(gate web "scp -t /tmp/x")"                 "deny"
has "gate: deny empty (shell)"  "$(gate web "")"                              "deny"
has "gate: deny bare sudo"      "$(gate web "sudo bash")"                     "deny"
# allow must carry the argv offset the gate execs from
eq  "gate: sudo offset"    "$(gate web "sudo $hd upload web r1")" "allow 2"
eq  "gate: no-sudo offset" "$(gate web "$hd upload web r1")"      "allow 1"

# --- cert_gate_decision: the box-scoped policy for hosted deploy certificates ---
# A certificate is scoped to a box — one user's box, every app on it — so the
# gate drops ci-gate's per-app pin and nothing else. Same verbs, same denials.
cgate() { cert_gate_decision "$1"; }
has "cgate: upload any app"       "$(cgate "sudo $hd upload web r1")"        "allow"
has "cgate: activate another app" "$(cgate "sudo $hd activate shop r1")"     "allow"
has "cgate: version"              "$(cgate "sudo $hd version")"              "allow"
has "cgate: no-sudo form"         "$(cgate "$hd status web")"                "allow"
eq  "cgate: sudo offset"          "$(cgate "sudo $hd upload web r1")"        "allow 2"
eq  "cgate: no-sudo offset"       "$(cgate "$hd activate web r1")"           "allow 1"
has "cgate: deny remove"          "$(cgate "sudo $hd remove web --yes")"     "deny"
has "cgate: deny self-update"     "$(cgate "sudo $hd self-update")"          "deny"
has "cgate: deny key-add"         "$(cgate "sudo $hd key-add")"              "deny"
has "cgate: deny key-rm"          "$(cgate "sudo $hd key-rm x")"             "deny"
has "cgate: deny tls-set"         "$(cgate "sudo $hd tls-set web")"          "deny"
has "cgate: deny firewall-set"    "$(cgate "sudo $hd firewall-set")"         "deny"
has "cgate: deny caddy-env-set"   "$(cgate "sudo $hd caddy-env-set X")"      "deny"
has "cgate: deny global-dns"      "$(cgate "sudo $hd global-dns cloudflare")" "deny"
has "cgate: deny ci-gate hop"     "$(cgate "sudo $hd ci-gate web x")"        "deny"
has "cgate: deny cert-gate hop"   "$(cgate "sudo $hd cert-gate x")"          "deny"
has "cgate: deny arbitrary cmd"   "$(cgate "cat /etc/shadow")"               "deny"
has "cgate: deny scp"             "$(cgate "scp -t /tmp/x")"                 "deny"
has "cgate: deny empty (shell)"   "$(cgate "")"                              "deny"
has "cgate: deny bare sudo"       "$(cgate "sudo bash")"                     "deny"
# box scope still requires a well-formed app name — "any app" must not become
# "any argument" to a verb that builds paths from it
has "cgate: deny missing app"     "$(cgate "sudo $hd activate")"             "deny"
has "cgate: deny path in app"     "$(cgate "sudo $hd upload ../etc r1")"     "deny"
has "cgate: deny uppercase app"   "$(cgate "sudo $hd upload Web r1")"        "deny"
has "cgate: deny shell in app"    "$(cgate "sudo $hd upload a;id r1")"       "deny"
# ci-gate's per-app pin is unchanged by sharing the allow-list
has "gate: still pinned to app"   "$(gate web "sudo $hd activate shop r1")"  "deny"

# --- origin auth: prove a request came through OUR Cloudflare zone ---
# Cloudflare's IP ranges are shared by every customer, so a firewall that
# allows them only proves "came via Cloudflare". Anyone can point their own
# proxied hostname at our IP (and override Host). A secret header added by a
# Transform Rule on our zone proves the rest. Every public site must check it —
# including inside each gateway handle block, because Caddy runs handle_path
# BEFORE a site-level abort, which would otherwise make gateways a bypass.
write_caddy oa oa.example.com 8110 plain 1
has "oa: proxied site checks origin" "$(cat "$CADDY_DIR/oa.caddy")" "import homeport_origin_auth"
for m in plain template idle; do
  has "oa: $m proxy strips the header" "$(emit_reverse_proxy '' "$m" ' 127.0.0.1:1')" "header_up -X-Origin-Auth"
done
write_caddy_static oas oas.example.com 0
has "oa: static site checks origin" "$(cat "$CADDY_DIR/oas.caddy")" "import homeport_origin_auth"
eq  "oa: every redirect host checks origin" \
    "$(REDIRECT_FROM=a.example.com,b.example.com emit_redirect_from oar oar.example.com | grep -c 'import homeport_origin_auth')" "2"
# redir sorts BEFORE abort in Caddy's directive order, so the check and the
# redirect must sit in a route (literal order) or aliases answer without it.
rd=$(REDIRECT_FROM=a.example.com emit_redirect_from oar oar.example.com)
eq  "oa: redirect check precedes redir inside a route" \
    "$(awk '/route \{/{r=1} r&&/import homeport_origin_auth/{i=NR} r&&/redir /{d=NR} END{print (r && i && d && i<d) ? "yes" : "no"}' <<<"$rd")" "yes"
write_caddy_internal oai 8111 1
eq  "oa: loopback service does not" "$(grep -c 'homeport_origin_auth' "$CADDY_DIR/oai.caddy")" "0"
# gateway: the check must be the first thing inside EVERY handle block
oa_etc=$(mktemp -d); saved_etc=${HOMEPORT_ETC:-}; HOMEPORT_ETC=$oa_etc
mkdir -p "$oa_etc/ga" "$oa_etc/gb"
printf 'DOMAIN=gw.example.com\nPATH_PREFIX=/a\nPORT=8120\n' > "$oa_etc/ga/config"
printf 'DOMAIN=gw.example.com\nPATH_PREFIX=/b/c\nPORT=8121\n' > "$oa_etc/gb/config"
write_gateway gw.example.com
gwf=$(ls "$CADDY_DIR"/_gw_*.caddy 2>/dev/null | head -1)
eq  "oa: gateway has a handle per app + fallback" "$(grep -cE '^\s*handle(_path)? ' "$gwf")" "3"
eq  "oa: every gateway handle opens with the check" \
    "$(awk '/^[[:space:]]*handle(_path)? /{want=1; next} want{ if ($0 ~ /import homeport_origin_auth/) ok++; want=0 } END{print ok+0}' "$gwf")" "3"
HOMEPORT_ETC=$saved_etc; rm -rf "$oa_etc"
# the snippet: defined (empty) when off, so every import resolves
off=$(origin_auth_snippet "")
has "oa: off still defines the snippet" "$off" "(homeport_origin_auth) {"
eq  "oa: off enforces nothing" "$(grep -c abort <<<"$off")" "0"
on=$(origin_auth_snippet "Zx9_k-3QpL7mN2vR8tY4wE6uI1oA5sD0fG_hJ-kLzXc")
has "oa: on matches the exact header" "$on" 'not header X-Origin-Auth "Zx9_k-3QpL7mN2vR8tY4wE6uI1oA5sD0fG_hJ-kLzXc"'
has "oa: on aborts the rest" "$on" "abort @homeport_origin_unauthenticated"
# the secret lands in a Caddyfile: anything that could close a quote or a
# block would be config injection, so the charset is closed
oasec() { (valid_origin_secret "$1") >/dev/null 2>&1 && echo ok || echo deny; }
eq "oa: accepts a 43-char base64url secret" "$(oasec Zx9_k-3QpL7mN2vR8tY4wE6uI1oA5sD0fG_hJ-kLzXc)" "ok"
eq "oa: rejects short"      "$(oasec short-secret)"                              "deny"
eq "oa: rejects a quote"    "$(oasec 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"x')"  "deny"
eq "oa: rejects a brace"    "$(oasec 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}')"  "deny"
eq "oa: rejects a space"    "$(oasec 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa a')" "deny"
eq "oa: rejects a newline"  "$(oasec $'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\na')" "deny"
eq "oa: rejects \$"         "$(oasec 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa$x')" "deny"

# rotation overlap: two accepted values while the Cloudflare rule is switched
A=Zx9_k-3QpL7mN2vR8tY4wE6uI1oA5sD0fG_hJ-kLzXc B=Qq1_w-2ErT3yU4iO5pA6sD7fG8hJ9kL0zX1cV2bN3m
two=$(origin_auth_snippet "$A" "$B")
eq  "oa: overlap accepts both" "$(grep -c 'not header X-Origin-Auth' <<<"$two")" "2"
eq  "oa: current values parsed back" "$(origin_auth_values <<<"$two" | paste -sd, -)" "$A,$B"
eq  "oa: off parses to nothing" "$(origin_auth_snippet "" | origin_auth_values | wc -l | tr -d ' ')" "0"
# on/off state lives in the snippet file alone; ensure never clobbers "on"
ORIGIN_AUTH_FRAG=$CADDY_DIR/00-origin-auth.caddy; rm -f "$ORIGIN_AUTH_FRAG"
ensure_origin_auth_snippet
eq  "oa: ensure creates it off" "$(origin_auth_on && echo on || echo off)" "off"
origin_auth_snippet "Zx9_k-3QpL7mN2vR8tY4wE6uI1oA5sD0fG_hJ-kLzXc" > "$ORIGIN_AUTH_FRAG"
ensure_origin_auth_snippet
eq  "oa: ensure keeps it on" "$(origin_auth_on && echo on || echo off)" "on"
has "oa: status never prints the secret" "$(cmd_origin_auth_status)" "origin-auth: on"
eq  "oa: status never prints the secret (value)" "$(cmd_origin_auth_status | grep -c Zx9_k)" "0"
# the snippet sorts before every app/gateway fragment (Caddy globs lexically,
# and a snippet must be defined before it is imported)
eq  "oa: snippet sorts first" "$(printf '%s\n' 00-origin-auth.caddy _gw_x.caddy a.caddy 0app.caddy | LC_ALL=C sort | head -1)" "00-origin-auth.caddy"
# only the box owner may toggle it — never CI or the platform
has "oa: ci-gate denies set"   "$(gate web "sudo $hd origin-auth-set")"   "deny"
has "oa: cert-gate denies set" "$(cgate "sudo $hd origin-auth-clear")"    "deny"
# apply: re-renders fragments that predate the feature, and on a validation
# failure restores EVERY fragment byte-for-byte (a half-applied change leaves
# some sites open and others unreachable).
ap_fails=0
( fails=0; ap_etc=$(mktemp -d); HOMEPORT_ETC=$ap_etc
  mkdir -p "$ap_etc/legacy"
  printf 'DOMAIN=legacy.example.com\nPORT=8130\n' > "$ap_etc/legacy/config"
  printf 'legacy.example.com {\n\treverse_proxy 127.0.0.1:8130\n}\n' > "$CADDY_DIR/legacy.caddy"
  chown() { :; }; chmod() { :; }; systemctl() { :; }
  before=$(cat "$CADDY_DIR"/*.caddy | cksum)
  caddy_validate() { return 1; }
  ( printf '%s\n' "$A" | cmd_origin_auth_set ) >/dev/null 2>&1 && { echo "FAIL oa: apply should die on invalid config"; fails=$((fails + 1)); }
  eq "oa: failed apply restores every fragment" "$(cat "$CADDY_DIR"/*.caddy | cksum)" "$before"
  caddy_validate() { return 0; }
  printf '%s\n' "$A" | cmd_origin_auth_set >/dev/null
  has "oa: apply re-renders legacy sites" "$(cat "$CADDY_DIR/legacy.caddy")" "import homeport_origin_auth"
  eq  "oa: apply turns it on" "$(origin_auth_on && echo on || echo off)" "on"
  printf '%s\n' "$B" | cmd_origin_auth_set --keep-previous >/dev/null
  eq  "oa: keep-previous holds both, newest first" "$(origin_auth_values < "$ORIGIN_AUTH_FRAG" | paste -sd, -)" "$B,$A"
  cmd_origin_auth_retire >/dev/null
  eq  "oa: retire keeps only the newest" "$(origin_auth_values < "$ORIGIN_AUTH_FRAG" | paste -sd, -)" "$B"
  rm -rf "$ap_etc" "$CADDY_DIR/legacy.caddy"
  exit "$fails" ) || ap_fails=$?
fails=$((fails + ap_fails))
origin_auth_snippet "$A" "$B" > "$ORIGIN_AUTH_FRAG"
has "oa: status flags a rotation in progress" "$(cmd_origin_auth_status)" "rotation in progress"
rm -f "$ORIGIN_AUTH_FRAG"

# --- C1 regression: health path is source'd as root, so it MUST reject any
#     shell-active character (this was a root RCE via a scoped CI key's `add`) ---
hp_ok() { [[ ${1:-} =~ ^/[A-Za-z0-9._/-]*$ ]]; }
eq "health /healthz allowed"    "$(hp_ok /healthz  && echo ok)"        "ok"
eq "health / allowed"           "$(hp_ok /         && echo ok)"        "ok"
eq "health rejects \$()"        "$(hp_ok '/h$(id)'      || echo deny)" "deny"
eq "health rejects backtick"    "$(hp_ok '/h`id`'       || echo deny)" "deny"
eq "health rejects \${IFS}"     "$(hp_ok '/h${IFS}x'    || echo deny)" "deny"
eq "health rejects semicolon"   "$(hp_ok '/h;id'        || echo deny)" "deny"
eq "health rejects space"       "$(hp_ok '/h x'         || echo deny)" "deny"


# --- host ownership helpers must return 0 on not-found under set -e ---
# (regression: a failed [[ ]]&& at the loop tail returned 1, and the caller's
# owner=$(host_alias_owner …) assignment silently killed homeportd)
HOMEPORT_ETC=$(mktemp -d)
mkdir -p "$HOMEPORT_ETC/website"
printf 'DOMAIN=homeport.sh\nALIASES=www.homeport.sh\nREDIRECT_FROM=\n' > "$HOMEPORT_ETC/website/config"
if out=$(set -e; host_alias_owner nope.example.com newapp; echo SURVIVED); [[ $out == *SURVIVED* ]]; then
  printf 'ok   host_alias_owner: not-found survives set -e\n'
else
  printf 'FAIL host_alias_owner: not-found dies under set -e\n'; fails=$((fails + 1))
fi
if out=$(set -e; host_owned_by nope.example.com newapp; echo SURVIVED); [[ $out == *SURVIVED* ]]; then
  printf 'ok   host_owned_by: not-found survives set -e\n'
else
  printf 'FAIL host_owned_by: not-found dies under set -e\n'; fails=$((fails + 1))
fi
eq "host_alias_owner finds alias" "$(host_alias_owner www.homeport.sh newapp)" "website"
rm -rf "$HOMEPORT_ETC"

echo "----"
if (( fails > 0 )); then echo "$fails bash test(s) FAILED"; exit 1; fi
echo "all bash tests passed"
