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
# The admin API is Caddy's control plane: whoever can reach it can replace the
# whole config (drop origin-auth, take over another app's hostname). On TCP
# loopback that is every local user and every app. A unix socket in caddy's
# 0750 home is reachable by caddy and root only — so the block always exists.
g=$(cat "$CADDY_GLOBALS_FRAG" 2>/dev/null)
has "globals: admin on a private unix socket even with nothing else set" "$g" $'\tadmin unix//var/lib/caddy/admin.sock|0600\n'
has "globals: still a global options block" "$g" $'{\n'
if [[ $g == *"localhost:2019"* || $g == *"admin off"* ]]; then
  printf 'FAIL globals: admin left on TCP (or off — which breaks reloads)\n'; fails=$((fails + 1))
else printf 'ok   globals: admin not on TCP\n'; fi
GDNS_PROVIDER=cloudflare GDNS_ENV=HOMEPORT_DNS_CLOUDFLARE
write_caddy_globals
has "globals: admin kept alongside dns" "$(cat "$CADDY_GLOBALS_FRAG")" "admin unix//var/lib/caddy/admin.sock|0600"
GDNS_PROVIDER="" GDNS_ENV=""
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
# A deploy certificate is scoped to ONE app (cert-gate <app>): on a shared host
# the box holds other customers' apps. These run as a certificate for "web".
cgate() { cert_gate_decision web "$1"; }
has "cgate: upload its own app"   "$(cgate "sudo $hd upload web r1")"        "allow"
has "cgate: deny another app"     "$(cgate "sudo $hd activate shop r1")"     "deny"
has "cgate: deny another app (add)" "$(cgate "sudo $hd add shop - / 256M 50% true - 1 - - - - - gvisor")" "deny"
has "cgate: register its own app" "$(cgate "sudo $hd add web - / 256M 50% true - 1 - - - - - gvisor")" "allow"
# the control plane retires an app (the customer deleted it) by removing it
# from its host — its own app only, and only in the confirmed form
has "cgate: remove its own app"            "$(cgate "sudo $hd remove web --yes")"   "allow"
has "cgate: deny removing another app"     "$(cgate "sudo $hd remove shop --yes")"  "deny"
has "cgate: deny remove without --yes"     "$(cgate "sudo $hd remove web")"         "deny"
has "cgate: deny remove with extra args"   "$(cgate "sudo $hd remove web --yes x")" "deny"
# a CI key never removes, even its own app (same gate code, different door)
has "ci-gate: still denies remove"         "$(gate web "sudo $hd remove web --yes")" "deny"
# the box-wide form (no app) and a wildcard scope are refused outright
has "cgate: deny an unscoped certificate" "$(cert_gate_decision "" "sudo $hd upload web r1")" "deny"
has "cgate: deny a wildcard scope"        "$(cert_gate_decision "*" "sudo $hd upload web r1")" "deny"
has "cgate: deny an invalid scope"        "$(cert_gate_decision "../x" "sudo $hd upload ../x r1")" "deny"
# runtime logs: the control plane reads its own app's journal and sets the
# plan's limits - never another app's, and not a CI key
has "cgate: read its own logs"             "$(cgate "sudo $hd logs-read web - 200")" "allow"
has "cgate: read on from a cursor"         "$(cgate "sudo $hd logs-read web s=ab12;i=3f;b=9c;m=1a;t=5e;x=77 200")" "allow"
has "cgate: deny another app's logs"       "$(cgate "sudo $hd logs-read shop - 200")" "deny"
has "cgate: deny logs-read without a count" "$(cgate "sudo $hd logs-read web -")" "deny"
has "cgate: set its own log limits"        "$(cgate "sudo $hd logs-limits web 7 500")" "allow"
has "cgate: deny another app's limits"     "$(cgate "sudo $hd logs-limits shop 7 500")" "deny"
has "ci-gate: no logs-read"                "$(gate web "sudo $hd logs-read web - 200")" "deny"
has "cgate: version"              "$(cgate "sudo $hd version")"              "allow"
has "cgate: no-sudo form"         "$(cgate "$hd status web")"                "allow"
eq  "cgate: sudo offset"          "$(cgate "sudo $hd upload web r1")"        "allow 2"
eq  "cgate: no-sudo offset"       "$(cgate "$hd activate web r1")"           "allow 1"
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

# --- app units: no cloud metadata service --------------------------------------
# 169.254.169.254 serves the droplet's user-data and metadata to anyone on the
# box who asks. An app has no business there; a compromised one would.
for sb in "" relaxed; do
  body=$(app=imds user=imds HOMEPORT_ROOT=/opt/homeport SANDBOX=$sb emit_service_body 8140)
  has "units: metadata endpoint denied (sandbox=${sb:-default})" "$body" "IPAddressDeny=169.254.0.0/16"
done

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

# --- env values: what you push is what the app gets ----------------------------
# The env file is read by systemd (the app) AND bash (deploy hooks); stored raw,
# systemd dropped unquoted backslashes and bash split on spaces. Values are now
# decoded once (.env rules) and stored canonically: KEY="…" escaping \ " ` $,
# which both read back exactly.
dv() { env_decode_value "$1"; }
eq "env: unquoted backslash is literal (the bug)"  "$(dv 'a\b')" 'a\b'
eq "env: windows path"                             "$(dv 'C:\path\to\x')" 'C:\path\to\x'
eq "env: double quotes stripped"                   "$(dv '"a b"')" 'a b'
eq "env: escaped quote inside double quotes"       "$(dv '"say \"hi\""')" 'say "hi"'
eq "env: \\n stays two characters (as systemd)"     "$(dv '"a\nb"')" 'a\nb'
eq "env: single quotes are literal"                "$(dv "'x\\y'")" 'x\y'
eq "env: surrounding whitespace trimmed (as systemd)" "$(dv '  spaced  ')" 'spaced'
eq "env: quote mid-value is literal"               "$(dv 'tricky "value" with \ backslash')" 'tricky "value" with \ backslash'
eq "env: unterminated quote is literal"            "$(dv '"unterminated')" '"unterminated'
eq "env: no expansion"                             "$(dv '$(id) `id` $HOME')" '$(id) `id` $HOME'
env_bad=0
for v in 'a\b' '\' '\\' '"' "'" 'it'"'"'s' 'p@ss w0rd!' '$HOME' '`id`' '$(touch /tmp/pwned)' 'C:\path\to' 'héllo wörld' 'a"b\c$d`e' ' lead' 'trail '; do
  enc=$(env_encode_value "$v")
  # canonical lines decode back exactly…
  [[ $(env_decode_value "$enc") == "$v" ]] || { echo "decode(encode(${v})) = [$(env_decode_value "$enc")]"; env_bad=1; }
  # …and bash (deploy hooks) reads them back exactly, executing nothing
  got=$(f=$(mktemp); printf 'K=%s\n' "$enc" > "$f"; ( set -a; . "$f"; printf '%s' "$K" ); rm -f "$f")
  [[ $got == "$v" ]] || { echo "bash read [$got] want [$v]"; env_bad=1; }
  env_is_canonical "K=$enc" || { echo "not canonical: K=$enc"; env_bad=1; }
done
eq "env: encode → decode and encode → bash are exact" "$env_bad" "0"
[[ ! -e /tmp/pwned ]] && ok_line=ok || ok_line=EXECUTED; eq "env: a value never executes" "$ok_line" "ok"
eq "env: raw legacy line is not canonical"  "$(env_is_canonical 'K=a\b' && echo yes || echo no)" "no"
# normalising a legacy file keeps every value's intent, in order, idempotently
lf=$(mktemp); printf '%s\n' 'A=a\b' 'B="quoted v"' "C='lit\\x'" '# comment' 'D= spaced ' 'A=second' > "$lf"
eq "env: render a legacy file canonically" "$(env_render_file "$lf")" $'A="second"\nB="quoted v"\nC="lit\\\\x"\nD="spaced"'
printf '%s\n' "$(env_render_file "$lf")" > "$lf.2"
eq "env: rendering is idempotent" "$(env_render_file "$lf.2")" "$(cat "$lf.2")"
rm -f "$lf" "$lf.2"

# --- usage metering ------------------------------------------------------------
# Awake time in (last, now], from systemd's own timestamps (µs, monotonic):
# meter_awake_us <last> <now> <state> <active-enter> <inactive-enter>
aw() { meter_awake_us "$@"; }
eq "meter: awake the whole minute"        "$(aw 1000 61000 active   500 0)"     "60000"
eq "meter: woke mid-minute"               "$(aw 1000 61000 active   31000 500)" "30000"
eq "meter: slept mid-minute"              "$(aw 1000 61000 inactive 500 21000)" "20000"
eq "meter: woke and slept within it"      "$(aw 1000 61000 inactive 11000 41000)" "30000"
eq "meter: asleep the whole minute"       "$(aw 1000 61000 inactive 200 500)"  "0"
eq "meter: never started"                 "$(aw 1000 61000 inactive 0 0)"      "0"
eq "meter: failed counts like asleep"     "$(aw 1000 61000 failed 200 500)"    "0"
eq "meter: stopping still counts as awake" "$(aw 1000 61000 deactivating 500 0)" "60000"
# counters: growth is the delta; a restart (new identity) or a counter that went
# backwards starts over; the first sight of an instance only sets a baseline —
# metering never bills usage from before it was watching
dl() { meter_delta "$@"; }
eq "meter: counter growth"                "$(dl 100 250 same)"  "150"
eq "meter: restart → new counter"         "$(dl 100 40 new)"    "40"
eq "meter: counter went backwards"        "$(dl 100 40 same)"   "40"
eq "meter: first sight sets a baseline"   "$(dl '' 9000 new)"   "0"
# which units/ports an app's instances are
eq "meter: plain app"   "$(PORT=8100 REPLICAS=1 IDLE= AUTOSCALE_MAX= meter_instances web)" "homeport-web 8100"
eq "meter: idle app serves on its internal port" "$(PORT=8100 REPLICAS=1 IDLE=true AUTOSCALE_MAX= meter_instances web)" "homeport-web 9100"
rb=$(replica_base 8100)
eq "meter: replicas" "$(PORT=8100 REPLICAS=2 IDLE= AUTOSCALE_MAX= meter_instances web)" "homeport-web@$((rb+1)) $((rb+1))"$'\n'"homeport-web@$((rb+2)) $((rb+2))"
eq "meter: autoscale watches every slot up to max" "$(PORT=8100 REPLICAS=1 IDLE= AUTOSCALE_MAX=4 meter_instances web | wc -l | tr -d ' ')" "4"
eq "meter: size 512M" "$(meter_mb 512M)" "512"
eq "meter: size 1G"   "$(meter_mb 1G)" "1024"
eq "meter: no size"   "$(meter_mb '')" "0"
rec=$(meter_record 7 100 160 web 256 60000 120 4096)
eq "meter: record" "$rec" '{"seq":7,"start":100,"end":160,"app":"web","memory_mb":256,"awake_ms":60000,"mb_ms":15360000,"cpu_ms":120,"egress_bytes":4096}'
command -v jq >/dev/null && eq "meter: record is JSON" "$(jq -r .mb_ms <<<"$rec")" "15360000"
# the spool: numbered records, read after a sequence number, deleted only once
# the control plane confirms it stored them; numbering never repeats
( METER_DIR=$(mktemp -d)
  for i in 1 2 3 4 5; do meter_append "$(meter_record __SEQ__ $i $((i+60)) web 256 1000 0 0)"; done
  eq "meter: read after 2" "$(meter_read 2 | jq -r .seq | paste -sd, -)" "3,4,5"
  meter_ack 4
  eq "meter: ack drops what was stored" "$(meter_read 0 | jq -r .seq | paste -sd, -)" "5"
  meter_append "$(meter_record __SEQ__ 9 69 web 256 1000 0 0)"
  eq "meter: numbering survives an ack" "$(meter_read 0 | jq -r .seq | paste -sd, -)" "5,6"
  eq "meter: reading never deletes" "$(meter_read 0 | wc -l | tr -d ' ')" "2"
  rm -rf "$METER_DIR"
  exit "$fails" ) || fails=$((fails + $?))
# the control plane's meter certificate may read and confirm usage — nothing else
mg() { meter_gate_decision "$1"; }
has "meter-gate: read"              "$(mg "sudo $hd meter-read 12")"   "allow"
has "meter-gate: ack"               "$(mg "sudo $hd meter-ack 12")"    "allow"
has "meter-gate: deny a deploy"     "$(mg "sudo $hd upload web r1")"   "deny"
has "meter-gate: deny status"       "$(mg "sudo $hd status web")"      "deny"
has "meter-gate: deny bad seq"      "$(mg "sudo $hd meter-read 1;id")" "deny"
has "meter-gate: deny a shell"      "$(mg "")"                         "deny"
has "meter-gate: deny other binaries" "$(mg "cat /var/lib/homeport/meter/spool")" "deny"

# host-gate: the control plane's host-certificate renewal — install a new
# host certificate, nothing else
hg() { host_gate_decision "$1"; }
has "host-gate: install"            "$(hg "sudo $hd host-cert-install")"       "allow"
has "host-gate: no arguments"       "$(hg "sudo $hd host-cert-install x")"     "deny"
has "host-gate: deny a deploy"      "$(hg "sudo $hd upload web r1")"           "deny"
has "host-gate: deny meter"         "$(hg "sudo $hd meter-read 0")"            "deny"
has "host-gate: deny a shell"       "$(hg "")"                                 "deny"
has "host-gate: deny other binaries" "$(hg "tee /etc/ssh/ssh_host_ed25519_key-cert.pub")" "deny"

# build-gate: the control plane's build certificate on a builder - run one
# build (its job on stdin), nothing else
bg() { build_gate_decision "$1"; }
has "build-gate: run"               "$(bg "sudo $hd build-run")"               "allow"
has "build-gate: no arguments"      "$(bg "sudo $hd build-run --as-root")"     "deny"
has "build-gate: deny a deploy"     "$(bg "sudo $hd upload web r1")"           "deny"
has "build-gate: deny host certs"   "$(bg "sudo $hd host-cert-install")"       "deny"
has "build-gate: deny a shell"      "$(bg "")"                                 "deny"
has "build-gate: deny other binaries" "$(bg "bash -c id")"                     "deny"

# build_job_check: the job from the control plane, every field in its shape
(
  host_arch() { echo x86-64; }
  bj=$(mktemp)
  job() { # job <jq update> - a valid job, changed
    jq -n '{build: "0b910ee5-6f1e-4c55-9d1a-2f6c1f0a9b11", app: "1c2d3e4f-0000-4000-8000-000000000001",
      sha: "0123456789abcdef0123456789abcdef01234567", arch: "x86-64",
      source: "https://codeload.github.com/alice/blog/legacy.tar.gz/sha?token=abc",
      upload: "https://nyc3.digitaloceanspaces.com/artifacts/a/b?X-Amz-Signature=def",
      timeout: 900}' | jq "$1" > "$bj"
  }
  job .
  has "job: a good one" "$(build_job_check "$bj" && echo "$BJ_SHA $BJ_ARCH $BJ_TIMEOUT")" \
    "0123456789abcdef0123456789abcdef01234567 x86-64 900"
  for bad in '.build = "x"' '.app = "../etc"' '.sha = "main"' '.arch = "arm64"' \
             '.source = "http://codeload.github.com/x"' '.upload = "file:///etc/passwd"' \
             '.source = "https://x\"; rm -rf /"' '.upload = "https://x/ y"' \
             '.timeout = 5' '.timeout = 99999' '.timeout = "900"' 'del(.sha)'; do
    job "$bad"
    has "job: refuse $bad" "[$( (build_job_check "$bj") >/dev/null 2>&1; echo $?)]" "[1]"
  done
  # where the run plan goes: optional (an older control plane sends none)
  job '.plan = "https://nyc3.digitaloceanspaces.com/artifacts/a/plan?X-Amz-Signature=ghi"'
  has "job: a plan link" "$(build_job_check "$bj" && echo "$BJ_PLAN")" "https://nyc3.digitaloceanspaces.com/artifacts/a/plan"
  job .; eq "job: no plan link is fine" "$(build_job_check "$bj" && echo "[$BJ_PLAN]")" "[]"
  for bad in '.plan = "http://x/plan"' '.plan = "https://x/ y"' '.plan = 5'; do
    job "$bad"
    has "job: refuse $bad" "[$( (build_job_check "$bj") >/dev/null 2>&1; echo $?)]" "[1]"
  done
  printf 'not json' > "$bj"
  has "job: refuse garbage" "[$( (build_job_check "$bj") >/dev/null 2>&1; echo $?)]" "[1]"
  rm -f "$bj"
)

# build_spec: the build's sandbox - unprivileged, its checkout and cache
# mounted, the image's own environment, network through its slot
(
  ie=$(mktemp)
  printf '%s\n' "PATH=/usr/local/go/bin:/usr/bin:/bin" "GOLANG_VERSION=1.24.2" > "$ie"
  spec=$(build_spec --uid 64000 --gid 64000 --src /var/lib/homeport/builds/b1/src \
    --cache /var/lib/homeport/build-cache/a1 --netns /var/run/netns/hp-62001 \
    --script "bun install --frozen-lockfile && bun run build" --image-env "$ie")
  rm -f "$ie"
  q() { jq -r "$1" <<<"$spec"; }
  has "spec: unprivileged"            "$(q '.process.user | "\(.uid):\(.gid)"')" "64000:64000"
  has "spec: no new privileges"       "$(q '.process.noNewPrivileges')" "true"
  has "spec: no capabilities"         "$(q '.process.capabilities.bounding | length')" "0"
  has "spec: runs the plan in a shell" "$(q '.process.args | join(" ")')" "/bin/sh -ec bun install --frozen-lockfile && bun run build"
  has "spec: in the checkout"         "$(q '.process.cwd')" "/src"
  has "spec: the image's PATH"        "$(q '.process.env | join(" ")')" "PATH=/usr/local/go/bin:/usr/bin:/bin"
  has "spec: the image's env"         "$(q '.process.env | join(" ")')" "GOLANG_VERSION=1.24.2"
  has "spec: caches in /cache"        "$(q '.process.env | join(" ")')" "GOMODCACHE=/cache/go/mod"
  has "spec: home in /cache"          "$(q '.process.env | join(" ")')" "HOME=/cache/home"
  has "spec: checkout mounted rw"     "$(q '.mounts[] | select(.destination == "/src") | "\(.source) \(.options | join(","))"')" "/var/lib/homeport/builds/b1/src rbind,rw"
  has "spec: cache mounted rw"        "$(q '.mounts[] | select(.destination == "/cache") | .source')" "/var/lib/homeport/build-cache/a1"
  has "spec: its own network"         "$(q '.linux.namespaces[] | select(.type == "network") | .path')" "/var/run/netns/hp-62001"
  has "spec: nothing else of the host" "[$(q '[.mounts[].source] | map(select(startswith("/etc") or startswith("/root") or startswith("/var/lib/homeport/apps"))) | length')]" "[0]"
)
# the shared prefix parse every gate uses
has "gate_offset: via sudo"         "[$(gate_offset "sudo $hd version")]"      "[2]"
has "gate_offset: direct"           "[$(gate_offset "$hd version")]"           "[1]"
has "gate_offset: anything else"    "[$(gate_offset "bash -c id")]"            "[]"

# host_cert_check: a host certificate for THIS host's key, naming it, expiring
hc=$(mktemp -d)
ssh-keygen -q -t ed25519 -N '' -f "$hc/ca" -C ca
ssh-keygen -q -t ed25519 -N '' -f "$hc/host" -C host
ssh-keygen -q -t ed25519 -N '' -f "$hc/other" -C other
sign() { # sign <out> <key> <extra ssh-keygen args...>
  local out=$1 key=$2; shift 2
  cp "$key.pub" "$hc/tosign.pub"
  ssh-keygen -q -s "$hc/ca" -I host/0b910ee5 "$@" "$hc/tosign.pub" 2>/dev/null
  mv "$hc/tosign-cert.pub" "$out"
}
sign "$hc/good"    "$hc/host"  -h -n 203.0.113.9 -V -1m:+30d
sign "$hc/user"    "$hc/host"     -n 203.0.113.9 -V -1m:+30d
sign "$hc/theirs"  "$hc/other" -h -n 203.0.113.9 -V -1m:+30d
sign "$hc/expired" "$hc/host"  -h -n 203.0.113.9 -V 20200101:20200102
sign "$hc/anyhost" "$hc/host"  -h               -V -1m:+30d
sign "$hc/forever" "$hc/host"  -h -n 203.0.113.9
echo "not a certificate" > "$hc/garbage"
hcc() { host_cert_check "$hc/$1" "$hc/host.pub" >/dev/null 2>&1; echo "[rc=$?]"; }
has "host cert: a good one"            "$(hcc good)"    "[rc=0]"
has "host cert: refuse a user cert"    "$(hcc user)"    "[rc=1]"
has "host cert: refuse another key"    "$(hcc theirs)"  "[rc=1]"
has "host cert: refuse expired"        "$(hcc expired)" "[rc=1]"
has "host cert: refuse any-host"       "$(hcc anyhost)" "[rc=1]"
has "host cert: refuse never-expiring" "$(hcc forever)" "[rc=1]"
has "host cert: refuse garbage"        "$(hcc garbage)" "[rc=1]"

# cmd_host_cert_install: installs a good certificate; refuses a bad one and
# keeps the old; puts the old back if sshd won't take the new
(
  SSH_HOST_KEY=$hc/host
  log() { :; }; die() { echo "DIE $*"; exit 1; }
  sshd_ok=1; sshd() { (( sshd_ok )); }
  reloads=0; systemctl() { echo "reload" >> "$hc/reloads"; }
  echo "old-cert" > "$hc/host-cert.pub"
  out=$(cmd_host_cert_install < "$hc/good" 2>&1)
  has "install: good cert installed" "$(cat "$hc/host-cert.pub")" "$(cat "$hc/good")"
  has "install: sshd reloaded"       "$(cat "$hc/reloads" 2>/dev/null)" "reload"
  cp "$hc/good" "$hc/host-cert.pub"; : > "$hc/reloads"
  out=$(cmd_host_cert_install < "$hc/theirs" 2>&1)
  has "install: bad cert refused"    "$out" "DIE certificate refused"
  has "install: bad cert, old kept"  "$(cat "$hc/host-cert.pub")" "$(cat "$hc/good")"
  sshd_ok=0
  sign "$hc/good2" "$hc/host" -h -n 203.0.113.9 -V -1m:+20d
  out=$(cmd_host_cert_install < "$hc/good2" 2>&1)
  has "install: sshd says no"        "$out" "DIE sshd rejected"
  has "install: sshd says no, old back" "$(cat "$hc/host-cert.pub")" "$(cat "$hc/good")"
  has "install: no reload on failure" "[$(cat "$hc/reloads")]" "[]"
  has "install: no temp files left"  "[$(ls -A "$hc" | grep -c '^\.homeport-cert')]" "[0]"
)
rm -rf "$hc"
# and a deploy certificate can't read other tenants' usage
has "cgate: deny meter-read"        "$(cgate "sudo $hd meter-read 0")" "deny"

# --- pause / resume (abuse response; reversible, nothing deleted) ---------------
# systemctl is stubbed: we check what pause/resume ask systemd to do per mode.
( fails=0
  pr_etc=$(mktemp -d); HOMEPORT_ETC=$pr_etc
  sc_log=$(mktemp); systemctl() { echo "$*" >> "$sc_log"; }
  mkapp() { mkdir -p "$pr_etc/$1"; printf '%s\n' "$2" > "$pr_etc/$1/config"; }
  ran() { cat "$sc_log"; : > "$sc_log"; }

  mkapp web $'PORT=8100\nREPLICAS=1'
  cmd_pause web >/dev/null
  out=$(ran)
  has "pause: stops and disables the app"      "$out" "disable --now homeport-web"
  eq  "pause: recorded in the config"          "$(grep -c '^PAUSED=1$' "$pr_etc/web/config")" "1"
  ( cmd_pause web ) >/dev/null 2>&1 && ok_p=ok || ok_p=deny
  eq  "pause: a second pause is harmless"      "$ok_p" "ok"
  ( cmd_add web - / >/dev/null 2>&1 ) && a=allowed || a=refused
  eq  "pause: add is refused (a deploy must not un-pause it)" "$a" "refused"
  ( cmd_activate web r1 >/dev/null 2>&1 ) && a=allowed || a=refused
  eq  "pause: activate is refused"             "$a" "refused"
  ( cmd_rollback web >/dev/null 2>&1 ) && a=allowed || a=refused
  eq  "pause: rollback is refused"             "$a" "refused"
  ran >/dev/null
  cmd_resume web >/dev/null
  has "resume: enables and starts it again"    "$(ran)" "enable --now homeport-web"
  eq  "resume: no longer paused"               "$(grep -c '^PAUSED=' "$pr_etc/web/config")" "0"

  # scale-to-zero: the socket must go too, or the next request wakes it
  mkapp idl $'PORT=8101\nREPLICAS=1\nIDLE=true'
  cmd_pause idl >/dev/null
  out=$(ran)
  has "pause idle: socket disabled (traffic can't wake it)" "$out" "disable --now homeport-idl-proxy.socket"
  has "pause idle: proxy stopped"              "$out" "stop homeport-idl-proxy.service"
  has "pause idle: app stopped"                "$out" "disable --now homeport-idl"
  cmd_resume idl >/dev/null
  out=$(ran)
  has "resume idle: socket back"               "$out" "enable --now homeport-idl-proxy.socket"
  eq  "resume idle: the app itself waits for traffic" "$(grep -c 'enable --now homeport-idl$' <<<"$out")" "0"

  # replicas: every instance, and the autoscaler stops scaling it back up
  mkapp rep $'PORT=8102\nREPLICAS=2\nAUTOSCALE_MAX=3'
  touch "$pr_etc/rep.timer-marker"
  cmd_pause rep >/dev/null
  out=$(ran)
  rb=$(replica_base 8102)
  for i in 1 2 3; do has "pause replicas: instance $i" "$out" "disable --now homeport-rep@$((rb+i))"; done
  has "pause replicas: autoscaler off"         "$out" "disable --now homeport-rep-autoscale.timer"
  cmd_resume rep >/dev/null
  out=$(ran)
  for i in 1 2; do has "resume replicas: instance $i" "$out" "enable --now homeport-rep@$((rb+i))"; done
  eq  "resume replicas: only the current count" "$(grep -c "homeport-rep@$((rb+3))" <<<"$out")" "0"
  has "resume replicas: autoscaler on"         "$out" "enable --now homeport-rep-autoscale.timer"

  mkapp st $'PORT=0\nSTATIC=1'
  ( cmd_pause st >/dev/null 2>&1 ) && a=allowed || a=refused
  eq  "pause: a static site has nothing to pause" "$a" "refused"
  rm -rf "$pr_etc" "$sc_log"
  exit "$fails" ) || fails=$((fails + $?))
# only the control plane's certificate pauses and resumes — its own app only
has "cgate: pause its own app"      "$(cgate "sudo $hd pause web")"   "allow"
has "cgate: resume its own app"     "$(cgate "sudo $hd resume web")"  "allow"
has "cgate: deny pausing another"   "$(cgate "sudo $hd pause shop")"  "deny"
has "cgate: deny pause extra args"  "$(cgate "sudo $hd pause web x")" "deny"
has "ci-gate: never pauses"         "$(gate web "sudo $hd pause web")"  "deny"
has "ci-gate: never resumes"        "$(gate web "sudo $hd resume web")" "deny"

# --- sandbox: gvisor (multi-tenant runner) --------------------------------
# Each instance (keyed by the port it serves) gets its own /30 in 100.64/14:
# host side .1, sandbox .2. Unique per port, valid up to port 65535.
declare -A sb_seen=(); sb_bad=0
for p in $(seq 8100 8160) $(seq 9100 9110) $(seq 10001 10040) 65535; do
  g=$(sandbox_ip "$p" guest); h=$(sandbox_ip "$p" host)
  [[ $g =~ ^100\.(6[4-7])\.([0-9]+)\.([0-9]+)$ && ${BASH_REMATCH[2]} -le 255 && ${BASH_REMATCH[3]} -le 254 ]] || { echo "bad guest ip for $p: $g"; sb_bad=1; }
  [[ ${h%.*} == "${g%.*}" && $(( ${g##*.} - ${h##*.} )) == 1 ]] || { echo "host/guest not a pair for $p: $h $g"; sb_bad=1; }
  [[ -z ${sb_seen[$g]:-} ]] || { echo "guest ip reused: $g ($p, ${sb_seen[$g]})"; sb_bad=1; }
  sb_seen[$g]=$p
done
eq "sandbox: one valid, unique /30 per port" "$sb_bad" "0"
# runsc matches container IDs by PREFIX (the spike sent an exec to the wrong
# tenant): no id may ever be a prefix of another.
sb_ids=(); for a in a ab a-b web web-api; do for p in 8100 81000 9100 10001; do sb_ids+=("$(sandbox_id "$a" "$p")"); done; done
sb_pre=0
for x in "${sb_ids[@]}"; do for y in "${sb_ids[@]}"; do [[ $x != "$y" && $y == "$x"* ]] && { echo "prefix: $x < $y"; sb_pre=1; }; done; done
eq "sandbox: no container id is a prefix of another" "$sb_pre" "0"
eq "sandbox: native apps stay on loopback" "$(SANDBOX= app_addr 8100)" "127.0.0.1"
eq "sandbox: gvisor apps are reached at their sandbox" "$(SANDBOX=gvisor app_addr 8100)" "$(sandbox_ip 8100 guest)"
eq "sandbox: caddy upstream (plain)" "$(SANDBOX=gvisor app_upstreams 8100 plain 1)" " $(sandbox_ip 8100 guest):8100"
eq "sandbox: caddy upstreams (replicas)" "$(SANDBOX=gvisor app_upstreams 8100 template 2 | wc -w | tr -d ' ')" "2"
has "sandbox: replica upstreams are sandboxes" "$(SANDBOX=gvisor app_upstreams 8100 template 2)" "$(sandbox_ip "$(( $(replica_base 8100) + 2 ))" guest):$(( $(replica_base 8100) + 2 ))"

# the unit: systemd supervises (restart, cgroup limits); homeportd builds the
# sandbox and execs runsc — as root, because runsc needs it to set up the
# sandbox, which is what then holds the app's code.
sbu=$(app=web user=homeport-web HOMEPORT_ROOT=/opt/homeport SANDBOX=gvisor limits=$'MemoryMax=256M\nCPUQuota=50%' emit_service_body 8100)
has "sandbox unit: starts the sandbox"    "$sbu" "ExecStart=/usr/local/bin/homeportd sandbox-run web 8100"
has "sandbox unit: graceful stop"         "$sbu" "ExecStop=/usr/local/bin/homeportd sandbox-stop web 8100"
has "sandbox unit: always cleans up"      "$sbu" "ExecStopPost=/usr/local/bin/homeportd sandbox-clean web 8100"
has "sandbox unit: app env from the file" "$sbu" "EnvironmentFile=-/opt/homeport/web/shared/env"
has "sandbox unit: memory limit"          "$sbu" "MemoryMax=256M"
has "sandbox unit: cpu limit"             "$sbu" "CPUQuota=50%"
has "sandbox unit: pids limit"            "$sbu" "TasksMax="
has "sandbox unit: restarts on failure"   "$sbu" "Restart=on-failure"
has "sandbox unit: runsc gets the stop"   "$sbu" "KillMode=mixed"
# every tenant runs in one slice capped below the host's RAM: however many
# wake at once, together they can't starve the host's own services
has "sandbox unit: in the tenant slice"   "$sbu" "Slice=homeport-tenants.slice"
G=$((1024 * 1024 * 1024))
eq "slice: 16 GiB host keeps 10% back"      "$(tenant_slice_max_bytes $((16 * 1024 * 1024)))" "$(( (16 * G - 16 * G / 10) / 4096 * 4096 ))"
odd=$(tenant_slice_max_bytes 15123457)       # a MemTotal that isn't a round number
eq "slice: whole pages, as the kernel stores it" "$(( odd % 4096 ))" "0"
eq "slice: 4 GiB host keeps 1 GiB back"     "$(tenant_slice_max_bytes $((4 * 1024 * 1024)))"  "$(( 3 * G ))"
eq "slice: a tiny host still gives tenants half" "$(tenant_slice_max_bytes $((1024 * 1024)))" "$(( G / 2 ))"
slu=$(tenant_slice_unit $(( 3 * G )))
has "slice unit: hard cap"                "$slu" "MemoryMax=$(( 3 * G ))"
has "slice unit: reclaim before the cap"  "$slu" "MemoryHigh=$(( 3 * G / 10 * 9 ))"
has "slice unit: no swap"                 "$slu" "MemorySwapMax=0"
# swap would absorb a memory bomb: a memory limit means RAM+swap (CI runner
# with swap: a 600M allocation under MemoryMax=256M simply survived)
has "sandbox unit: swap can't dodge the memory limit" "$sbu" "MemorySwapMax=0"
# the app exits 143 on SIGTERM; a clean stop must not leave a failed unit
has "sandbox unit: SIGTERM exit is a clean stop" "$sbu" "SuccessExitStatus=143 SIGTERM"
eq  "sandbox unit: no swap cap without a memory limit" \
    "$(app=web user=homeport-web HOMEPORT_ROOT=/opt/homeport SANDBOX=gvisor limits= emit_service_body 8100 | grep -c MemorySwapMax)" "0"
eq  "sandbox unit: no native exec of the binary" "$(grep -c '^ExecStart=/opt/homeport' <<<"$sbu")" "0"
eq  "sandbox unit: no User= (runsc drops privileges itself)" "$(grep -c '^User=' <<<"$sbu")" "0"
has "sandbox unit: replicas keep %i" "$(app=web user=homeport-web HOMEPORT_ROOT=/opt/homeport SANDBOX=gvisor limits= emit_service_body '%i')" "sandbox-run web %i"
nsu=$(app=web user=homeport-web HOMEPORT_ROOT=/opt/homeport SANDBOX= limits= emit_service_body 8100)
has "native unit unchanged" "$nsu" "ExecStart=/opt/homeport/web/current/bin"
# a tenant's logs go to its own journal: its own size, retention and rate
# limit, so a noisy app can't evict the others' logs on a shared host
has "sandbox unit: its own journal"       "$sbu" "LogNamespace=hp-web"
eq  "native unit: the system journal"     "$(grep -c LogNamespace <<<"$nsu")" "0"
jc=$(journal_conf 7 500)
has "journal: on disk"                    "$jc" "Storage=persistent"
has "journal: size cap"                   "$jc" "SystemMaxUse=500M"
has "journal: retention"                  "$jc" "MaxRetentionSec=7day"
has "journal: a flood is rate limited"    "$jc" "RateLimitBurst="
lv() { (valid_log_limits "$@") >/dev/null 2>&1 && echo ok || echo deny; }
eq "log limits: in range"                 "$(lv 1 10; lv 365 10240)" $'ok\nok'
eq "log limits: out of range or not numbers" "$(lv 0 500; lv 7 5; lv 400 500; lv 7 99999; lv x 500; lv 7 '5;id')" $'deny\ndeny\ndeny\ndeny\ndeny\ndeny'
# logs-read: journalctl on the app's namespace, as JSON, from a cursor
lr() { (logs_read_args "$@") 2>/dev/null | tr '\n' ' '; }
has "logs-read: the app's namespace"      "$(lr web - 200)" "--namespace=hp-web"
has "logs-read: structured"               "$(lr web - 200)" "-o json"
has "logs-read: the last N to start"      "$(lr web - 200)" "-n 200"
has "logs-read: on from a cursor"         "$(lr web 's=ab;i=3f' 200)" "--after-cursor=s=ab;i=3f"
eq  "logs-read: no cursor, no after"      "$(lr web - 200 | grep -c after-cursor)" "0"
eq  "logs-read: a bad cursor refused"     "$(lr web 's=ab i=3' 200; lr web '$(id)' 200; lr web 's=ab' 0; lr web 's=ab' 99999)" ""
eq  "native unit: not in the tenant slice" "$(grep -c 'Slice=' <<<"$nsu")" "0"

# hooks run natively as the app user — customer code outside the sandbox — so
# a gvisor app may not have them (until hooks run sandboxed too)
sbv() { (validate_sandbox "$@") >/dev/null 2>&1 && echo ok || echo deny; }
eq "sandbox: gvisor accepted"             "$(sbv gvisor "" "")" "ok"
eq "sandbox: strict/relaxed/unset accepted" "$(sbv strict "" ""; sbv relaxed "" ""; sbv "" "" "")" $'ok\nok\nok'
eq "sandbox: unknown value refused"       "$(sbv docker "" "")" "deny"
# a gvisor app's release command runs in a sandbox of its own: args to ./bin,
# like run (there's no shell inside), so no shell syntax and no variables
eq "sandbox: gvisor + release args accepted"     "$(sbv gvisor "$(b64 'artisan migrate --force')" "")" "ok"
eq "sandbox: gvisor + release shell refused"     "$(sbv gvisor "$(b64 'php artisan migrate && echo done')" "")" "deny"
eq "sandbox: gvisor + release variable refused"  "$(sbv gvisor "$(b64 'migrate $DATABASE_URL')" "")" "deny"
eq "sandbox: gvisor + post_release hook refused" "$(sbv gvisor "" "bWlncmF0ZQ==")" "deny"
eq "sandbox: strict + hooks still fine"   "$(sbv strict "bWlncmF0ZQ==" "bWlncmF0ZQ==")" "ok"

# the OCI spec: everything the sandbox is allowed, in one reviewed place
if command -v jq >/dev/null; then
  sbenv=$(mktemp)
  printf 'SECRET=a "quoted" \\ value\nwith a newline\0PORT=8100\0INVOCATION_ID=abc\0JOURNAL_STREAM=8:9\0PATH=/sbin\0' > "$sbenv"
  spec=$(sandbox_spec --uid 997 --gid 996 --cwd /opt/homeport/web/current --bin /opt/homeport/web/current/bin \
         --args "serve --port 8100" --release /opt/homeport/web/releases/r1 --shared /opt/homeport/web/shared \
         --netns /var/run/netns/hp-8100 --hostname web --env-file "$sbenv")
  rm -f "$sbenv"
  j() { jq -r "$1" <<<"$spec"; }
  eq "spec: read-only root"            "$(j .root.readonly)" "true"
  eq "spec: runs as the app's uid"     "$(j .process.user.uid)" "997"
  eq "spec: never as root"             "$(j '.process.user.uid != 0')" "true"
  eq "spec: no new privileges"         "$(j .process.noNewPrivileges)" "true"
  eq "spec: no capabilities"           "$(j '[.process.capabilities // {} | .[] | length] | add // 0')" "0"
  eq "spec: argv"                      "$(j '.process.args | join(" ")')" "/opt/homeport/web/current/bin serve --port 8100"
  eq "spec: same cwd as native"        "$(j .process.cwd)" "/opt/homeport/web/current"
  eq "spec: secret survives exactly"   "$(j '.process.env[] | select(startswith("SECRET="))')" $'SECRET=a "quoted" \\ value\nwith a newline'
  eq "spec: listens inside its netns"  "$(j '.process.env[] | select(startswith("HOST="))')" "HOST=0.0.0.0"
  eq "spec: systemd internals dropped" "$(j '[.process.env[] | select(test("^(INVOCATION_ID|JOURNAL_STREAM)="))] | length')" "0"
  eq "spec: sane PATH"                 "$(j '.process.env[] | select(startswith("PATH="))')" "PATH=/usr/local/bin:/usr/bin:/bin"
  eq "spec: release mounted read-only at current/" "$(j '.mounts[] | select(.destination=="/opt/homeport/web/current") | [.source, (.options|index("ro")!=null)] | join(" ")')" "/opt/homeport/web/releases/r1 true"
  eq "spec: shared dir writable"       "$(j '.mounts[] | select(.destination=="/opt/homeport/web/shared") | (.options|index("rw")!=null)')" "true"
  eq "spec: private /tmp"              "$(j '.mounts[] | select(.destination=="/tmp") | .type')" "tmpfs"
  eq "spec: every host bind is read-only except shared" "$(j '[.mounts[] | select(.type=="bind" and .destination!="/opt/homeport/web/shared") | select(.options|index("ro")==null)] | length')" "0"
  eq "spec: its own network namespace" "$(j '.linux.namespaces[] | select(.type=="network") | .path')" "/var/run/netns/hp-8100"
  eq "spec: own pid/ipc/uts/mount"     "$(j '[.linux.namespaces[].type] | sort | join(",")')" "ipc,mount,network,pid,uts"
else
  echo "skip: jq not installed (spec tests)"
fi

# outbound policy: the policy is in the link's NAME, so re-applying the
# firewall can never lose a sandbox's policy (no per-sandbox state)
eq "egress: full sandboxes use hpv<port>"     "$(sandbox_veth 8100 full)" "hpv8100"
eq "egress: unset means full"                 "$(sandbox_veth 8100 '')"   "hpv8100"
eq "egress: web-only sandboxes use hpvw<port>" "$(sandbox_veth 8100 web)"  "hpvw8100"
eq "egress: names fit IFNAMSIZ at port 65535" "$(( $(sandbox_veth 65535 web | wc -c) - 1 <= 15 ))" "1"
ev() { (validate_egress "$@") >/dev/null 2>&1 && echo ok || echo deny; }
eq "egress: web/full/unset with gvisor"  "$(ev gvisor web; ev gvisor full; ev gvisor '')" $'ok\nok\nok'
eq "egress: unknown policy refused"      "$(ev gvisor open)" "deny"
eq "egress: only for sandboxed apps"     "$(ev strict web)" "deny"

# the host firewall for sandboxes: reach the internet, nothing of ours
fw=$(sandbox_firewall_rules)
has "fw: sandboxes can't reach host services" "$fw" 'iifname "hpv*" drop'
has "fw: …but replies to the host get back"   "$fw" 'iifname "hpv*" ct state established,related accept'
for d in 169.254.0.0/16 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8; do
  has "fw: no egress to $d" "$fw" "$d"
done
has "fw: no sandbox-to-sandbox"   "$fw" 'iifname "hpv*" oifname "hpv*" drop'
has "fw: nothing unsolicited in"  "$fw" 'oifname "hpv*" drop'
has "fw: egress is NATed"         "$fw" 'masquerade'
# mail is blocked for every sandbox (blacklisted IPs hurt every tenant on a host)
has "fw: no outbound mail, any tier" "$fw" 'iifname "hpv*" tcp dport { 25, 465, 587 } drop'
# web-only (the free tier): web, DNS and database ports — nothing else
has "fw: web-only tcp ports"   "$fw" 'iifname "hpvw*" tcp dport != { 53, 80, 443, 3306, 5432, 6379, 27017 } drop'
has "fw: web-only udp is DNS"  "$fw" 'iifname "hpvw*" udp dport != 53 drop'
has "fw: web-only nothing else" "$fw" 'iifname "hpvw*" meta l4proto != { tcp, udp } drop'
eq  "fw: policy drops come before the egress accept" \
    "$(awk '/dport .*25, 465, 587/{m=NR} /l4proto != /{w=NR} /iifname "hpv\*" accept/{a=NR} END{print (m && w && a && m<a && w<a) ? "yes" : "no"}' <<<"$fw")" "yes"
eq  "fw: deny rules come before the egress accept" \
    "$(awk '/169.254.0.0\/16/{d=NR} /iifname "hpv\*" accept/{a=NR} END{print (d && a && d<a) ? "yes" : "no"}' <<<"$fw")" "yes"

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

# run_plan: how the app runs, from build-plan's output, for the control plane
if command -v jq >/dev/null; then
  rp=$(run_plan '{"toolchain":"go","image":"golang:1","command":"go build","artifact":"server","run":"serve","release":"migrate","processes":[{"name":"worker","run":"work"}]}')
  eq "run_plan: only how it runs" "$rp" '{"run":"serve","release":"migrate","processes":[{"name":"worker","run":"work"}]}'
  eq "run_plan: nothing to run"   "$(run_plan '{"toolchain":"go","image":"golang:1","command":"go build","artifact":"server"}')" '{"run":"","release":"","processes":[]}'
fi

# --- processes: a worker or scheduler beside the web process ---
# each is args to ./bin with its own limits ("-" = the app's), in a port slot
# of its own: a range past every app's replica block, 8 slots an app
eq "proc_base: first app"          "$(proc_base 8100)" "30000"
eq "proc_base: next app"           "$(proc_base 8101)" "30008"
(( $(proc_base 8100) > $(replica_base 9099) + 19 )) && echo "ok   proc_base: clear of the last replica block" \
  || { echo "FAIL proc_base overlaps the replica blocks"; fails=$((fails + 1)); }
eq "proc_unit: app_name, never another app's" "$(proc_unit web worker)" "homeport-web_worker"
procs=$(b64 $'worker - - artisan queue:work\nscheduler 128M 25% artisan schedule:work')
pp() { (parse_processes "$1") 2>/dev/null || echo deny; }
eq "processes: none"               "$(pp '')" ""
eq "processes: sorted, defaults kept" "$(pp "$procs")" $'scheduler 128M 25% artisan schedule:work\nworker - - artisan queue:work'
for bad in 'Worker - - run' 'web - - run' 'release - - run' 'a_b - - run' 'averyveryverylongname - - run' \
           'worker lots - run' 'worker - many run' 'worker - -' 'worker - - run;rm' 'worker - - run $HOME' \
           $'a - - x\nb - - x\nc - - x\nd - - x\ne - - x' $'w - - x\nw - - y'; do
  eq "processes: refused [${bad//$'\n'/|}]" "$(pp "$(b64 "$bad")")" "deny"
done
eq "proc_slot: release first, then each process" "$(proc_slot 8100 0) $(proc_slot 8100 1) $(proc_slot 8100 4)" "30000 30001 30004"

# what a sandbox runs: the web's args get its port; release and processes don't
RUN_B64=$(b64 'serve --port $PORT') RELEASE_B64=$(b64 'artisan migrate --force') PROCESSES_B64=$procs
eq "sandbox_args: web"      "$(sandbox_args web 8100)" "serve --port 8100"
eq "sandbox_args: release"  "$(sandbox_args release 30000)" "artisan migrate --force"
eq "sandbox_args: process"  "$(sandbox_args worker 30002)" "artisan queue:work"
eq "sandbox_args: unknown"  "$( (sandbox_args nope 30003) 2>/dev/null || echo deny)" "deny"
RUN_B64=- RELEASE_B64=-
eq "sandbox_args: no run"   "$(sandbox_args web 8100)" ""

# every unit the app runs, for pause, metering and logs: processes carry their
# own memory (MB) - billed at their size, not the app's
eq "meter: processes beside the web" "$(PORT=8100 REPLICAS=1 IDLE= AUTOSCALE_MAX= MEMORY=512M meter_instances web)" \
  $'homeport-web 8100\nhomeport-web_scheduler 30001 128\nhomeport-web_worker 30002 512'
unset RUN_B64 RELEASE_B64 PROCESSES_B64

eq "meter_record: web only, mb_ms = size × time" "$(meter_record 1 0 60 web 256 1000 5 0 | grep -o '"mb_ms":[0-9]*')" '"mb_ms":256000'
eq "meter_record: processes billed at their own size" "$(meter_record 1 0 60 web 256 2000 5 0 384000 | grep -o '"mb_ms":[0-9]*')" '"mb_ms":384000'

# add runs under set -e: an app without processes must get through these
(
  systemctl() { :; }
  PORT=8100 PROCESSES_B64=""
  out=$(set -e; write_process_units web 256M 50% ""; stop_processes web; echo SURVIVED)
  eq "no processes: add survives set -e" "$out" "SURVIVED"
)
# the units name each process's slot; written to a scratch dir
(
  systemctl() { :; }
  sysd=$(mktemp -d)
  write_units_in() { sed "s#/etc/systemd/system#$sysd#g" <<<"$(declare -f write_process_units)" > "$sysd/fn"; source "$sysd/fn"; }
  write_units_in
  app=web user=homeport-web HOMEPORT_ROOT=/opt/homeport SANDBOX=gvisor PORT=8100
  PROCESSES_B64=$(b64 $'worker - - work\nticker 128M - tick')
  write_process_units web 256M 50% ""
  has "add: a process unit runs its slot"   "$(cat "$sysd/homeport-web_ticker.service")" "sandbox-run web 30001 ticker"
  has "add: …with its own memory"           "$(cat "$sysd/homeport-web_ticker.service")" "MemoryMax=128M"
  has "add: …or the app's"                  "$(cat "$sysd/homeport-web_worker.service")" "MemoryMax=256M"
  has "add: …and the app's cpu"             "$(cat "$sysd/homeport-web_worker.service")" "CPUQuota=50%"
  rm -rf "$sysd"
)

# status --json reports each process: its state, and how often it restarted
if command -v jq >/dev/null; then
(
  systemctl() {
    case "$1 $2" in
      "is-active homeport-web_worker") echo active ;;
      "is-active homeport-web_ticker") echo activating ;;
      "is-active"*) echo active ;;
      "show homeport-web_ticker") echo 7 ;;
      "show"*) echo 0 ;;
    esac
  }
  HOMEPORT_ROOT=$(mktemp -d); mkdir -p "$HOMEPORT_ROOT/web/releases/r1"; ln -s releases/r1 "$HOMEPORT_ROOT/web/current"
  APP=web PORT=8100 DOMAIN=web.example.com REPLICAS=1 IDLE="" AUTOSCALE_MAX="" STATIC=""
  PROCESSES_B64=$(b64 $'worker - - work\nticker 128M - tick')
  sj=$(status_json_one web)
  eq "status: still JSON"                "$(jq -r .app <<<"$sj")" "web"
  eq "status: each process, by name"     "$(jq -r '[.processes[].name] | join(" ")' <<<"$sj")" "ticker worker"
  eq "status: a process's state"         "$(jq -r '.processes[] | select(.name=="worker") | .state' <<<"$sj")" "active"
  eq "status: …and its restarts"         "$(jq -r '.processes[] | select(.name=="ticker") | "\(.state) \(.restarts)"' <<<"$sj")" "activating 7"
  PROCESSES_B64=""
  eq "status: no processes is an empty list" "$(status_json_one web | jq -c .processes)" "[]"
  rm -rf "$HOMEPORT_ROOT"
)
fi

# a process unit: the app's body, its own ExecStart and limits
psu=$(app=web user=homeport-web HOMEPORT_ROOT=/opt/homeport SANDBOX=gvisor limits=$'MemoryMax=128M' emit_service_body 30001 scheduler)
has "process unit (gvisor): its own sandbox"   "$psu" "ExecStart=/usr/local/bin/homeportd sandbox-run web 30001 scheduler"
has "process unit (gvisor): cleaned by slot"   "$psu" "ExecStopPost=/usr/local/bin/homeportd sandbox-clean web 30001"
has "process unit (gvisor): the app's journal" "$psu" "LogNamespace=hp-web"
psn=$(app=web user=homeport-web HOMEPORT_ROOT=/opt/homeport SANDBOX= limits= RUN='artisan queue:work' emit_service_body 30002 worker)
has "process unit (native): its args"          "$psn" "ExecStart=/opt/homeport/web/current/bin artisan queue:work"

# --- the edge: one wildcard in front of every host -------------------------
# the route table: "<hostname> <host private IP>" lines - checked, sorted, one
# address per name; only private addresses (never loopback, the metadata
# service, or anywhere public), always the host's port 80
et=$(mktemp -d)
rl() { printf '%s\n' "$@" > "$et/routes"; (edge_route_lines "$et/routes") 2>/dev/null || echo deny; }
eq "edge routes: normalized and sorted" "$(rl 'Blog.homeport.run 10.0.0.5' 'api.homeport.run 10.116.0.9')" \
  $'api.homeport.run 10.116.0.9:80\nblog.homeport.run 10.0.0.5:80'
eq "edge routes: 172.16/12 and 192.168/16" "$(rl 'a.homeport.run 172.31.2.3' 'b.homeport.run 192.168.1.1')" \
  $'a.homeport.run 172.31.2.3:80\nb.homeport.run 192.168.1.1:80'
printf '' > "$et/routes"; eq "edge routes: none yet is a table" "$( (edge_route_lines "$et/routes") 2>/dev/null || echo deny)" ""
for bad in 'a.homeport.run 1.2.3.4' 'a.homeport.run 127.0.0.1' 'a.homeport.run 169.254.169.254' 'a.homeport.run 172.32.0.1' \
           'a.homeport.run 10.0.0.5:22' 'a b 10.0.0.5' '-a.homeport.run 10.0.0.5' 'a.homeport.run 10.0.0.5 extra' \
           'a.homeport.run 10.0.0.256' 'a.homeport.run' $'a.homeport.run 10.0.0.5\na.homeport.run 10.0.0.6'; do
  eq "edge routes: refuse [${bad//$'\n'/|}]" "$(rl "$bad")" "deny"
done
rm -rf "$et"

EDGE_DIR=/etc/homeport/edge
site=$(edge_site homeport.run)
has "edge site: the wildcard and the apex"        "$site" "*.homeport.run, homeport.run {"
has "edge site: Cloudflare's origin certificate"  "$site" "tls $EDGE_DIR/origin.pem $EDGE_DIR/origin.key"
has "edge site: only through our Cloudflare zone" "$site" "import homeport_origin_auth"
has "edge site: the route table"                  "$site" "import $EDGE_DIR/routes.map"
has "edge site: an unknown name stops here"       "$site" 'respond @homeport_unrouted "No app here" 404'
eq  "edge site: a bad domain is refused"          "$( (edge_site 'not a domain') 2>/dev/null || echo deny)" "deny"

eg() { edge_gate_decision "$1"; }
has "edge-gate: the route table"      "$(eg "sudo $hd edge-routes")"    "allow"
has "edge-gate: no arguments"         "$(eg "sudo $hd edge-routes x")"  "deny"
has "edge-gate: nothing else"         "$(eg "sudo $hd edge-cert")"      "deny"
has "edge-gate: not a shell"          "$(eg "")"                        "deny"

# a host behind the edge: its apps serve plain HTTP, to the edge alone
eo=$(edge_only_snippet 10.116.0.3/32)
has "edge-only: anyone else is refused" "$eo" "not remote_ip 10.116.0.3/32"
has "edge-only: …by aborting"           "$eo" "abort @homeport_not_edge"
eq  "edge-only: unset is an empty snippet" "$(edge_only_snippet '')" $'# managed by homeport — edit via `homeportd edge-from`\n(homeport_edge_only) {\n}'
CADDY_DIR=$(mktemp -d); TLS_MODE=edge ALIASES="" HEADERS_B64="" REDIRECT_FROM=""
write_caddy shop shop.homeport.run 8120 plain 1
eb=$(cat "$CADDY_DIR/shop.caddy")
has "behind the edge: plain HTTP, TLS ended upstream" "$eb" "http://shop.homeport.run {"
has "behind the edge: the edge alone"                 "$eb" "import homeport_edge_only"
if [[ $eb == *"homeport_origin_auth"* ]]; then echo "FAIL behind the edge: origin auth (the edge strips its header)"; fails=$((fails + 1)); else echo "ok   behind the edge: no origin-auth check (the edge did it)"; fi
if [[ $eb == *"tls "* ]]; then echo "FAIL behind the edge: a tls directive"; fails=$((fails + 1)); else echo "ok   behind the edge: no tls directive"; fi
TLS_MODE=""; rm -rf "$CADDY_DIR"

# the proxies Caddy trusts for the visitor's address
CADDY_DIR=$(mktemp -d); CADDY_GLOBALS_FRAG=$CADDY_DIR/00-globals.caddy
GDNS_PROVIDER="" GECH="" GTRUSTED="173.245.48.0/20 10.116.0.3/32" write_caddy_globals
has "globals: trusted proxies" "$(cat "$CADDY_GLOBALS_FRAG")" "trusted_proxies static 173.245.48.0/20 10.116.0.3/32"
GTRUSTED="" write_caddy_globals
if grep -q trusted_proxies "$CADDY_GLOBALS_FRAG"; then echo "FAIL globals: trusted proxies when none"; fails=$((fails + 1)); else echo "ok   globals: none trusted by default"; fi
rm -rf "$CADDY_DIR"

echo "----"
if (( fails > 0 )); then echo "$fails bash test(s) FAILED"; exit 1; fi
echo "all bash tests passed"
