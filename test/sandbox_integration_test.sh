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
has()  { if [[ $2 == *"$3"* ]]; then ok "$1"; else fail "$1: [$3] not in [${2:0:300}]"; fi; }
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

# DigitalOcean's Ubuntu 24.04 mounts /run noexec (GitHub's runners don't):
# sandbox bundles there made gVisor's read-only remount fail ("operation not
# permitted") and no hosted app ever started. Run every test like DO's.
mount -o remount,noexec /run && ok "/run is noexec, as on DigitalOcean" || fail "remount /run noexec"

cleanup() {
  for a in probe probe-two probe-web probe-jobs probe-idle; do "$HD" remove "$a" --yes >/dev/null 2>&1 || true; done
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

echo "--- the tenant slice"
eq "the sandbox runs in the tenant slice" "$(systemctl show homeport-probe -p Slice --value)" "homeport-tenants.slice"
total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
slice_max=$(systemctl show homeport-tenants.slice -p MemoryMax --value)
eq "the slice is capped below the host's RAM" "$slice_max" "$(tenant_slice_max_bytes "$total_kb")"
[[ $slice_max =~ ^[0-9]+$ && $slice_max -lt $(( total_kb * 1024 )) ]] && ok "…leaving room for the host ($(( (total_kb * 1024 - slice_max) / 1048576 )) MiB)" || fail "slice MemoryMax [$slice_max] vs host $(( total_kb * 1024 ))"
eq "the cap is live in the kernel" "$(cat /sys/fs/cgroup/homeport.slice/homeport-tenants.slice/memory.max 2>/dev/null || cat /sys/fs/cgroup/homeport-tenants.slice/memory.max 2>/dev/null)" "$slice_max"

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

echo "--- runtime logs"
# each tenant logs to its own journal, read by the control plane through its
# app-scoped certificate, as JSON lines that carry a cursor to read on from
cg() { "$HD" cert-gate "$1" "sudo /usr/local/bin/homeportd $2"; }
get '/log?m=hello-from-probe' >/dev/null
curl -s --max-time 5 "http://$G2:$P2/log?m=hello-from-two" >/dev/null
sleep 2
lr=$(cg probe "logs-read probe - 200" 2>&1)
has "logs-read: the app's own output"          "$lr" "hello-from-probe"
has "logs-read: from its start"                "$lr" "probe listening on"
eq  "logs-read: never another tenant's"        "$(grep -c hello-from-two <<<"$lr")" "0"
eq  "logs-read: JSON lines with a cursor"      "$(tail -1 <<<"$lr" | jq -r 'has("__CURSOR") and has("MESSAGE")')" "true"
cur=$(tail -1 <<<"$lr" | jq -r .__CURSOR)
get '/log?m=after-the-cursor' >/dev/null; sleep 2
more=$(cg probe "logs-read probe $cur 200" 2>&1)
has "logs-read: on from a cursor"              "$more" "after-the-cursor"
eq  "logs-read: …and only what's new"          "$(grep -c hello-from-probe <<<"$more")" "0"
eq  "not in the system journal"                "$(journalctl -u homeport-probe --no-pager 2>/dev/null | grep -c hello-from-probe)" "0"
eq  "another app's certificate can't read it"  "$(cg probe-two "logs-read probe - 200" >/dev/null 2>&1 && echo read || echo refused)" "refused"
has "the app's journal starts at the defaults" "$(cat /etc/systemd/journald@hp-probe.conf)" "MaxRetentionSec=1day"
cg probe "logs-limits probe 7 500" >/dev/null
has "the control plane sets the plan's limits" "$(cat /etc/systemd/journald@hp-probe.conf)" "MaxRetentionSec=7day"
has "…and its size cap"                        "$(cat /etc/systemd/journald@hp-probe.conf)" "SystemMaxUse=500M"

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

echo "--- pause / resume (through the app's own certificate)"
"$HD" cert-gate probe-two "sudo /usr/local/bin/homeportd pause probe" >/dev/null 2>&1 \
  && fail "probe-two's certificate paused probe" || ok "a certificate can't pause another app"
"$HD" cert-gate probe "sudo /usr/local/bin/homeportd pause probe" >/dev/null && ok "paused" || fail "pause failed"
eq "paused: the unit is stopped"     "$(systemctl is-active homeport-probe 2>/dev/null)" "inactive"
eq "paused: and won't start on boot" "$(systemctl is-enabled homeport-probe 2>/dev/null)" "disabled"
eq "paused: it doesn't answer"       "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$G:$P/" || true)" "000"
"$HD" activate probe r1 >/dev/null 2>&1 && fail "activate un-paused it" || ok "paused: activate is refused"
eq "paused: still not running"       "$(systemctl is-active homeport-probe 2>/dev/null)" "inactive"
systemctl stop homeport-meter.timer; "$HD" meter-ack 999999999 >/dev/null
"$HD" meter-tick; sleep 2; "$HD" meter-tick
eq "paused: accrues no usage"        "$("$HD" meter-read 0 | jq -c --arg a probe 'select(.app == $a and .awake_ms > 0)' | wc -l | tr -d ' ')" "0"
systemctl start homeport-meter.timer
"$HD" cert-gate probe "sudo /usr/local/bin/homeportd resume probe" >/dev/null && ok "resumed" || fail "resume failed"
for i in $(seq 1 100); do [[ $(get /) == ok ]] && break; sleep 0.1; done
eq "resumed: it answers again"       "$(get /)" "ok"
eq "resumed: enabled again"          "$(systemctl is-enabled homeport-probe 2>/dev/null)" "enabled"

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

echo "--- processes and the release command"
# a worker and a smaller ticker beside the web; a release command before
# traffic moves - all in sandboxes of their own
b64w() { printf '%s' "$1" | base64 -w0; }
jobs_add() { # <release> <processes>
  "$HD" add probe-jobs - / 256M 100% - - 1 - - "$(b64w "$1")" - - gvisor - - - - - - - - - - "$(b64w "$2")" >/dev/null
}
JP=$'worker - - worker worker\nticker 128M - worker ticker'
jobs_add migrate "$JP" && ok "add with processes and a release command" || fail "add probe-jobs"
printf 'QUEUE=default\n' | "$HD" env probe-jobs >/dev/null
"$HD" upload probe-jobs r1 < /tmp/probe >/dev/null
out=$("$HD" activate probe-jobs r1 2>&1) && ok "activate runs the release, then the processes" || fail "activate probe-jobs: $out"
has "the release command's output is the deploy's" "$out" "migrated"
JS=$HOMEPORT_ROOT/probe-jobs/shared
read -r runs kern < "$JS/migrated" 2>/dev/null
eq  "release ran once"                           "$runs" "1"
[[ -n $kern && $kern != "$(uname -r)" ]] && ok "release ran in gVisor ($kern)" || fail "release kernel [$kern] vs host [$(uname -r)]"
eq  "release unit is gone afterwards"            "$(systemctl list-units --all --no-legend 'homeport-probe-jobs_release.service' | wc -l | tr -d ' ')" "0"
for pn in worker ticker; do
  eq "process $pn is running"                    "$(systemctl is-active "homeport-probe-jobs_$pn")" "active"
  eq "process $pn is in the tenant slice"        "$(systemctl show "homeport-probe-jobs_$pn" -p Slice --value)" "homeport-tenants.slice"
  beat=$(cat "$JS/beat-$pn" 2>/dev/null || echo 0)
  (( $(date +%s) - beat < 5 )) && ok "process $pn is working (heartbeat)" || fail "process $pn heartbeat [$beat]"
done
eq  "a process gets its own memory limit"        "$(systemctl show homeport-probe-jobs_ticker -p MemoryMax --value)" "$(( 128 * 1024 * 1024 ))"
eq  "…or the app's"                              "$(systemctl show homeport-probe-jobs_worker -p MemoryMax --value)" "$(( 256 * 1024 * 1024 ))"
has "status lists the processes"                 "$("$HD" status probe-jobs)" "process:  worker (active)"
sjj=$(cg probe-jobs "status probe-jobs --json")
eq  "status --json, through the app's certificate" "$(jq -r '[.processes[] | "\(.name)=\(.state)"] | join(" ")' <<<"$sjj")" "ticker=active worker=active"
has "a process's output is in the app's journal" "$(cg probe-jobs "logs-read probe-jobs - 500")" "beat ticker"

# billed at their own sizes: the ticker's 128M makes the app's MB·ms less
# than (web's 256M) × (everything's awake time)
systemctl stop homeport-meter.timer; "$HD" meter-ack 999999999 >/dev/null
"$HD" meter-tick; sleep 3; "$HD" meter-tick
jrec=$("$HD" meter-read 0 | jq -c 'select(.app == "probe-jobs")' | tail -1)
eq  "metered: web + 2 processes awake"           "$(jq -r '.awake_ms > 6000' <<<"$jrec")" "true"
eq  "metered: each at its own size"              "$(jq -r '.mb_ms < .memory_mb * .awake_ms and .mb_ms > 0' <<<"$jrec")" "true"
systemctl start homeport-meter.timer

# a failing release command aborts the deploy before anything moves
jobs_add migrate-fail "$JP"
"$HD" upload probe-jobs r2 < /tmp/probe >/dev/null
out=$("$HD" activate probe-jobs r2 2>&1) && fail "a failed release command deployed" || ok "a failed release command aborts the deploy"
has "…saying why"                                "$out" "migration failed"
eq  "…still on r1"                               "$(basename "$(readlink "$HOMEPORT_ROOT/probe-jobs/current")")" "r1"
eq  "…processes untouched"                       "$(systemctl is-active homeport-probe-jobs_worker)" "active"

# a process that won't stay up fails the deploy, which goes back to r1
jobs_add migrate $'worker - - worker worker\nbroken - - crash'
"$HD" upload probe-jobs r3 < /tmp/probe >/dev/null
out=$("$HD" activate probe-jobs r3 2>&1) && fail "a crashing process deployed" || ok "a process that won't stay up fails the deploy"
eq  "…reverted to r1"                            "$(basename "$(readlink "$HOMEPORT_ROOT/probe-jobs/current")")" "r1"
jobs_add migrate "$JP"
"$HD" activate probe-jobs r1 >/dev/null 2>&1 && ok "back to the good config" || fail "redeploy r1"
eq  "a dropped process is stopped"               "$(systemctl is-active homeport-probe-jobs_broken 2>/dev/null)" "inactive"
eq  "…and its unit is gone"                      "$([[ -e /etc/systemd/system/homeport-probe-jobs_broken.service ]] && echo present || echo gone)" "gone"

"$HD" pause probe-jobs >/dev/null
eq  "pause stops the processes"                  "$(systemctl is-active homeport-probe-jobs_worker 2>/dev/null)" "inactive"
"$HD" resume probe-jobs >/dev/null; sleep 2
eq  "resume brings them back"                    "$(systemctl is-active homeport-probe-jobs_worker 2>/dev/null)" "active"
JPORT=$(sed -n 's/^PORT=//p' "$HOMEPORT_ETC/probe-jobs/config")
"$HD" remove probe-jobs --yes >/dev/null
eq  "remove: process units gone"                 "$(ls /etc/systemd/system/homeport-probe-jobs_* 2>/dev/null | wc -l | tr -d ' ')" "0"
eq  "remove: process networks gone"              "$(ip link show "hpv$(proc_slot "$JPORT" 1)" >/dev/null 2>&1 && echo present || echo gone)" "gone"

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


echo "--- a scale-to-zero app (every hosted Hobby app)"
# The wake socket listens on the public port and the proxy forwards to the
# sandbox on the internal one (public + 1000): the app must get the internal
# PORT (sourcing its config gave it the public one), and activate's health
# check must go through the socket, which is also what wakes it.
# it takes 2s to start, as real apps do: a cold wake must wait that out
"$HD" add probe-idle - / 256M 100% true 60s 1 - - - - - gvisor - - - - - - - - - - >/dev/null &&
  printf 'PROBE_START_DELAY=2s\n' | "$HD" env probe-idle >/dev/null &&
  "$HD" upload probe-idle r1 < /tmp/probe >/dev/null &&
  "$HD" activate probe-idle r1 >/dev/null 2>&1 && ok "scale-to-zero: deploys, health-checked through its wake socket" ||
  { fail "scale-to-zero: deploy"; journalctl --namespace="$(log_namespace probe-idle)" -n 20 --no-pager; }
IP=$(grep -m1 '^PORT=' "$HOMEPORT_ETC/probe-idle/config" | cut -d= -f2)
eq "scale-to-zero: answers through its wake socket" "$(curl -s --max-time 20 "http://127.0.0.1:$IP/")" "ok"
# asleep, then ONE request: the proxy must not connect before the sandboxed
# app listens (gVisor takes a second or two), or the visitor gets a 502
systemctl stop homeport-probe-idle-proxy.service homeport-probe-idle.service 2>/dev/null
eq "scale-to-zero: a cold wake answers the first request" "$(curl -s --max-time 30 "http://127.0.0.1:$IP/")" "ok"
# the startup boost lifted its CPU limit while it started: the plan's is back
sleep 1
eq "scale-to-zero: its CPU limit is the plan's once it's up" \
  "$(cat "/sys/fs/cgroup$(cut -d: -f3 "/proc/$(systemctl show -p MainPID --value homeport-probe-idle.service)/cgroup")/cpu.max")" "100000 100000"
IIP=$((IP + 1000))
eq "scale-to-zero: the app listens on its internal port" "$(curl -s --max-time 5 "http://$(sandbox_ip "$IIP" guest):$IIP/")" "ok"
# the bundle mount is made in the app unit's own mount namespace
opts=$(nsenter -t "$(systemctl show -p MainPID --value homeport-probe-idle.service)" -m findmnt -no OPTIONS -T "$SANDBOX_STATE")
[[ -n $opts && $opts != *noexec* ]] && ok "sandbox bundles: exec allowed (gVisor remounts them)" || fail "sandbox bundles: [$opts]"
if [[ $fails -gt 0 ]]; then echo "$fails sandbox integration test(s) FAILED"; exit 1; fi
echo "all sandbox integration tests passed ($(runsc --version | head -1))"
