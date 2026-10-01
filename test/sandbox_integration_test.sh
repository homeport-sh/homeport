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
deploy_probe() { # <app> <memory> [egress]
  local app=$1 mem=$2 egress=${3:--}
  # add <app> <domain> <health> <memory> <cpu> <idle> <idle_timeout> <replicas>
  #     <autoscale> <run> <release> <post_release> <path> <sandbox>
  #     <strategy> … <aliases> (15–23, unset) <egress>
  "$HD" add "$app" - / "$mem" 100% - - 1 - - - - - gvisor - - - - - - - - - "$egress" >/dev/null || return 1
  printf 'SECRET=%s\n' "$SECRET" | "$HD" env "$app" >/dev/null || return 1
  "$HD" upload "$app" r1 < /tmp/probe >/dev/null || return 1
  "$HD" activate "$app" r1
}

cleanup() {
  for a in probe probe-two probe-web; do "$HD" remove "$a" --yes >/dev/null 2>&1 || true; done
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
# parity, not a literal: the env file is systemd's format (it consumes an
# unquoted backslash), and a sandboxed app must see exactly what a native one would
native=$(systemd-run --quiet --pipe --wait -p EnvironmentFile="$HOMEPORT_ROOT/probe/shared/env" /usr/bin/printenv SECRET)
eq "secret reaches the app exactly as a native unit gets it" "$(get '/env?k=SECRET')" "$native"
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

echo "--- usage metering"
eq "meter timer installed with the sandbox" "$(systemctl is-enabled homeport-meter.timer 2>/dev/null)" "enabled"
systemctl stop homeport-meter.timer   # the test ticks by hand; the timer would race it
"$HD" meter-ack 999999999 >/dev/null  # start from an empty spool
"$HD" meter-tick                      # baseline
t0=$(date +%s)
curl -s -o /dev/null --max-time 20 "http://$G:$P/blob?kb=2048"   # 2 MiB out of the sandbox
sleep 3
"$HD" meter-tick
el_ms=$(( ($(date +%s) - t0 + 1) * 1000 ))
recs=$("$HD" meter-read 0)
rec=$(jq -c --arg a probe 'select(.app == $a)' <<<"$recs" | tail -1)
[[ -n $rec ]] && ok "a usage record for the probe app" || fail "no usage record (spool: $recs)"
awake=$(jq -r .awake_ms <<<"$rec"); egress=$(jq -r .egress_bytes <<<"$rec")
[[ $awake -ge 2000 && $awake -le $(( el_ms + 2000 )) ]] && ok "awake time measured (${awake} ms of ~${el_ms} ms)" || fail "awake_ms $awake (elapsed ~${el_ms} ms)"
[[ $egress -ge $(( 2048 * 1024 )) && $egress -lt $(( 4 * 1024 * 1024 )) ]] && ok "bytes sent measured ($egress for a 2 MiB response)" || fail "egress_bytes $egress"
eq "billed size × time" "$(jq -r '.mb_ms == .memory_mb * .awake_ms and .memory_mb == 256' <<<"$rec")" "true"
eq "records are numbered" "$(jq -r .seq <<<"$recs" | sort -n | uniq -d | wc -l | tr -d ' ')" "0"
# the control plane's certificate: read and confirm, nothing else
eq "meter-gate serves reads" "$("$HD" meter-gate "sudo /usr/local/bin/homeportd meter-read 0" | wc -l | tr -d ' ')" "$(wc -l <<<"$recs" | tr -d ' ')"
"$HD" meter-gate "sudo /usr/local/bin/homeportd status probe" >/dev/null 2>&1 && fail "meter-gate ran status" || ok "meter-gate refuses anything but read/confirm"
last=$(jq -r .seq <<<"$recs" | sort -n | tail -1)
"$HD" meter-gate "sudo /usr/local/bin/homeportd meter-ack $last" >/dev/null
eq "confirmed records are gone" "$("$HD" meter-read 0 | wc -l | tr -d ' ')" "0"
systemctl start homeport-meter.timer

echo "--- outbound policy"
eq "full: any port out (github.com:22)"   "$(get '/dial?addr=github.com:22')" "connected"
eq "full: still no mail (smtp:587)"       "$(get '/dial?addr=smtp.gmail.com:587')" "blocked"
deploy_probe probe-web 256M web >/dev/null && ok "deploy a web-only tenant (the free tier)" || fail "deploy probe-web"
PW=$(sed -n 's/^PORT=//p' "$HOMEPORT_ETC/probe-web/config"); GW=$(sandbox_ip "$PW" guest)
getw() { curl -s --max-time 10 "http://$GW:$PW$1"; }
eq "web-only: its link says so"           "$(ip link show "hpvw$PW" >/dev/null 2>&1 && echo hpvw || echo other)" "hpvw"
eq "web-only: HTTPS out works"            "$(getw '/dial?addr=1.1.1.1:443')" "connected"
eq "web-only: DNS works"                  "$(getw '/resolve?name=example.com')" "resolved"
eq "web-only: other ports blocked (:22)"  "$(getw '/dial?addr=github.com:22')" "blocked"
eq "web-only: no mail (smtp:587)"         "$(getw '/dial?addr=smtp.gmail.com:587')" "blocked"
"$HD" remove probe-web --yes >/dev/null
eq "web-only link removed with the app"   "$(ip link show "hpvw$PW" >/dev/null 2>&1 && echo present || echo gone)" "gone"

echo "--- limits"
before=$(systemctl show homeport-probe -p NRestarts --value)
get '/alloc?mb=600' >/dev/null    # over the 256M MemoryMax
for i in $(seq 1 60); do [[ $(get /) == ok ]] && [[ $(systemctl show homeport-probe -p NRestarts --value) -gt $before ]] && break; sleep 1; done
after=$(systemctl show homeport-probe -p NRestarts --value)
if [[ $after -gt $before ]]; then ok "memory bomb killed the sandbox, systemd restarted it ($before -> $after)"
else fail "no restart after memory bomb ($before -> $after)"; systemctl show homeport-probe -p MemoryMax,MemorySwapMax,MemoryPeak; journalctl -u homeport-probe -n 15 --no-pager; fi
eq "app is back after the restart"            "$(get /)" "ok"
eq "the other tenant never noticed"           "$(curl -s --max-time 5 "http://$G2:$P2/")" "ok"
# either outcome is containment: the limit stops the fork loop and the app
# answers, or the bomb takes down ITS OWN sandbox (as in the spike) and
# systemd brings it back — the neighbour must not notice either way
started=$(get '/fork?n=2000')
if [[ $started =~ ^[0-9]+$ ]]; then
  [[ $started -lt 600 ]] && ok "process limit holds (started $started of 2000)" || fail "fork limit: started $started"
else
  for i in $(seq 1 60); do [[ $(get /) == ok ]] && break; sleep 1; done
  eq "fork bomb took down only its own sandbox, which came back" "$(get /)" "ok"
fi
eq "the other tenant never noticed the fork bomb" "$(curl -s --max-time 5 "http://$G2:$P2/")" "ok"

echo "--- stop and clean up"
# probe-two never hit a limit (probe's Result stays oom-kill from the bomb)
t0=$(date +%s%N); systemctl stop homeport-probe-two; t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
[[ $ms -lt 8000 ]] && ok "stops promptly (${ms} ms)" || fail "stop took ${ms} ms"
eq "a stop is clean, not failed" "$(systemctl show homeport-probe-two -p Result --value)" "success"
[[ $(systemctl show homeport-probe-two -p Result --value) == success ]] || journalctl -u homeport-probe-two -n 15 --no-pager
eq "stop leaves no sandbox network" "$(ip link show "hpv$P2" >/dev/null 2>&1 && echo present || echo gone)" "gone"
# the way the control plane retires an app: through its app-scoped certificate
"$HD" cert-gate probe-two "sudo /usr/local/bin/homeportd remove probe --yes" >/dev/null 2>&1 \
  && fail "probe-two's certificate removed probe" || ok "a certificate can't remove another app"
"$HD" cert-gate probe "sudo /usr/local/bin/homeportd remove probe --yes" >/dev/null \
  && ok "the app's own certificate removes it" || fail "cert-gate remove of its own app failed"
eq "unit gone"       "$(systemctl list-units --all --no-legend 'homeport-probe.service' | wc -l | tr -d ' ')" "0"
eq "netns gone"      "$(ip netns list | grep -c "^hp-$P\b" || true)" "0"
eq "veth gone"       "$(ip link show "hpv$P" >/dev/null 2>&1 && echo present || echo gone)" "gone"
eq "sandbox gone"    "$(runsc --root=/run/homeport-runsc list 2>/dev/null | grep -c "$(sandbox_id probe "$P")" || true)" "0"

if [[ $fails -gt 0 ]]; then echo "$fails sandbox integration test(s) FAILED"; exit 1; fi
echo "all sandbox integration tests passed ($(runsc --version | head -1))"
