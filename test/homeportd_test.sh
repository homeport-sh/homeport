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
has "gate: deny other app"      "$(gate web "sudo $hd activate shop r1")"     "deny"
has "gate: deny env other app"  "$(gate web "sudo $hd env-sync shop")"        "deny"
has "gate: deny arbitrary cmd"  "$(gate web "cat /etc/shadow")"               "deny"
has "gate: deny scp"            "$(gate web "scp -t /tmp/x")"                 "deny"
has "gate: deny empty (shell)"  "$(gate web "")"                              "deny"
has "gate: deny bare sudo"      "$(gate web "sudo bash")"                     "deny"
# allow must carry the argv offset the gate execs from
eq  "gate: sudo offset"    "$(gate web "sudo $hd upload web r1")" "allow 2"
eq  "gate: no-sudo offset" "$(gate web "$hd upload web r1")"      "allow 1"

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

echo "----"
if (( fails > 0 )); then echo "$fails bash test(s) FAILED"; exit 1; fi
echo "all bash tests passed"
