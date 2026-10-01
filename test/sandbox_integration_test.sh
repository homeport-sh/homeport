#!/usr/bin/env bash
# End-to-end test of `sandbox: gvisor` on a real Linux host with gVisor: deploys
# a probe app through homeportd's own add / env / upload / activate, then
# attacks the sandbox from inside the way a hostile tenant would, and checks
# what the host lets through. The unit tests check what we generate; this
# checks what the kernel, runsc and nftables actually do with it.
#
# Needs root, systemd, runsc, jq, nft, ip and go. Skips without them unless
# REQUIRE_SANDBOX=1 (CI sets it). It installs homeportd to /usr/local/bin and
# writes under /opt/homeport and /etc/homeport, so run it on a throwaway
# machine (a CI runner), never on a real box.
set -uo pipefail
cd "$(dirname "$0")/.."

need() {
  if ! command -v "$1" >/dev/null; then
    [[ ${REQUIRE_SANDBOX:-} == 1 ]] && { echo "missing $1 (REQUIRE_SANDBOX=1)"; exit 1; }
    echo "skip: $1 not installed"; exit 0
  fi
}
for t in runsc jq nft ip go systemctl; do need "$t"; done
if [[ $(id -u) != 0 ]]; then
  [[ ${REQUIRE_SANDBOX:-} == 1 ]] && { echo "must run as root"; exit 1; }
  echo "skip: needs root"; exit 0
fi

fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
eq()   { if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1: got [$2] want [$3]"; fi; }

HD=/usr/local/bin/homeportd
awk "/<<'HOMEPORTD_SCRIPT'/{f=1;next} /^HOMEPORTD_SCRIPT\$/{f=0} f" bootstrap/bootstrap.sh > /tmp/homeportd.new
install -m 755 /tmp/homeportd.new "$HD"
# shellcheck disable=SC1090
source "$HD"   # for sandbox_ip / sandbox_id (main is source-guarded)
set +e         # homeportd runs with -e; this test reports failures itself
id -u deploy >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin deploy
mkdir -p "$HOMEPORT_ETC" "$HOMEPORT_ROOT"

# a dynamically linked binary, like the Bun/Node apps this will run
CGO_ENABLED=1 go build -o /tmp/probe ./test/sandbox/probe || { echo "probe build failed"; exit 1; }
file /tmp/probe | grep -q 'dynamically linked' && ok "probe is dynamically linked" || fail "probe should be dynamic"

SECRET=$'tricky "value" with \\ backslash'
deploy_probe() { # <app> <memory>
  local app=$1 mem=$2
  # add <app> <domain> <health> <memory> <cpu> <idle> <idle_timeout> <replicas>
  #     <autoscale> <run> <release> <post_release> <path> <sandbox>
  "$HD" add "$app" - / "$mem" 100% - - 1 - - - - - gvisor >/dev/null || return 1
  printf 'SECRET=%s\n' "$SECRET" | "$HD" env "$app" >/dev/null || return 1
  "$HD" upload "$app" r1 < /tmp/probe >/dev/null || return 1
  "$HD" activate "$app" r1
}

cleanup() {
  for a in probe probe-two; do "$HD" remove "$a" --yes >/dev/null 2>&1 || true; done
  [[ -n ${listener_pid:-} ]] && kill "$listener_pid" 2>/dev/null
}
trap cleanup EXIT

echo "--- deploy through homeportd"
deploy_probe probe 256M && ok "deploy probe (add/env/upload/activate, health-checked)" || { fail "deploy probe"; journalctl -u homeport-probe -n 40 --no-pager; exit 1; }
# shellcheck disable=SC1090
source "$HOMEPORT_ETC/probe/config"
P=$PORT; G=$(sandbox_ip "$P" guest); H=$(sandbox_ip "$P" host)
get() { curl -s --max-time 10 "http://$G:$P$1"; }
eq "app answers at its sandbox address" "$(get /)" "ok"
eq "nothing answers on host loopback for it" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$P/" || true)" "000"

echo "--- what the app sees"
eq "secret reaches the app byte-for-byte" "$(get '/env?k=SECRET')" "$SECRET"
eq "listens on its own interface"         "$(get '/env?k=HOST')" "0.0.0.0"
eq "PORT"                                  "$(get '/env?k=PORT')" "$P"
eq "STATE_DIR"                             "$(get '/env?k=STATE_DIR')" "$HOMEPORT_ROOT/probe/shared"
eq "runs as the app user, not root"        "$(get /uid)" "$(id -u homeport-probe)"
kernel=$(get /kernel)
[[ -n $kernel && $kernel != "$(uname -r)" ]] && ok "app sees gVisor's kernel ($kernel), not the host's" || fail "kernel: got [$kernel], host [$(uname -r)]"
procs=$(get /procs); [[ $procs =~ ^[0-9]+$ && $procs -lt 10 ]] && ok "sees only its own processes ($procs)" || fail "procs visible: $procs"

echo "--- files"
eq "root filesystem is read-only"   "$(get '/write?path=/pwned')" "denied"
eq "its own release is read-only"   "$(get "/write?path=$HOMEPORT_ROOT/probe/current/pwned")" "denied"
eq "state dir is writable"          "$(get "/write?path=$HOMEPORT_ROOT/probe/shared/ok")" "written"
eq "/tmp is writable"               "$(get '/write?path=/tmp/ok')" "written"
eq "host secrets aren't there"      "$(get '/read?path=/etc/shadow')" "denied"
eq "no other app's files"           "$(get "/read?path=$HOMEPORT_ETC/probe/config")" "denied"

echo "--- network"
python3 -m http.server 18999 --bind 0.0.0.0 >/dev/null 2>&1 & listener_pid=$!
sleep 1
eq "internet egress works (1.1.1.1:443)"      "$(get '/dial?addr=1.1.1.1:443')" "connected"
eq "DNS works"                                "$(get '/resolve?name=example.com')" "resolved"
eq "no cloud metadata (169.254.169.254:80)"   "$(get '/dial?addr=169.254.169.254:80')" "blocked"
eq "no private networks (10.0.0.1:80)"        "$(get '/dial?addr=10.0.0.1:80')" "blocked"
eq "no host services via its gateway"         "$(get "/dial?addr=$H:18999")" "blocked"
host_ip=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')
eq "no host services via the host's own IP"   "$(get "/dial?addr=$host_ip:18999")" "blocked"

deploy_probe probe-two 256M >/dev/null && ok "deploy a second tenant" || fail "deploy probe-two"
# shellcheck disable=SC1090
P2=$(sed -n 's/^PORT=//p' "$HOMEPORT_ETC/probe-two/config"); G2=$(sandbox_ip "$P2" guest)
eq "tenant can't reach another tenant"        "$(get "/dial?addr=$G2:$P2")" "blocked"
eq "…and the host still can"                  "$(curl -s --max-time 5 "http://$G2:$P2/")" "ok"

echo "--- limits"
before=$(systemctl show homeport-probe -p NRestarts --value)
get '/alloc?mb=600' >/dev/null    # over the 256M MemoryMax
for i in $(seq 1 60); do [[ $(get /) == ok ]] && [[ $(systemctl show homeport-probe -p NRestarts --value) -gt $before ]] && break; sleep 1; done
after=$(systemctl show homeport-probe -p NRestarts --value)
[[ $after -gt $before ]] && ok "memory bomb killed the sandbox, systemd restarted it ($before -> $after)" || fail "no restart after memory bomb ($before -> $after)"
eq "app is back after the restart"            "$(get /)" "ok"
eq "the other tenant never noticed"           "$(curl -s --max-time 5 "http://$G2:$P2/")" "ok"
started=$(get '/fork?n=2000')
[[ $started =~ ^[0-9]+$ && $started -lt 600 ]] && ok "process limit holds (started $started of 2000)" || fail "fork limit: started [$started]"

echo "--- clean up"
"$HD" remove probe --yes >/dev/null
eq "unit gone"       "$(systemctl list-units --all --no-legend 'homeport-probe.service' | wc -l | tr -d ' ')" "0"
eq "netns gone"      "$(ip netns list | grep -c "^hp-$P\b" || true)" "0"
eq "veth gone"       "$(ip link show "hpv$P" >/dev/null 2>&1 && echo present || echo gone)" "gone"
eq "sandbox gone"    "$(runsc --root=/run/homeport-runsc list 2>/dev/null | grep -c "$(sandbox_id probe "$P")" || true)" "0"

if [[ $fails -gt 0 ]]; then echo "$fails sandbox integration test(s) FAILED"; exit 1; fi
echo "all sandbox integration tests passed ($(runsc --version | head -1))"
