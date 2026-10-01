#!/usr/bin/env bash
# What you push is what the app gets — checked against REAL systemd. Secrets go
# through the real `homeportd env`, then are read back the two ways an app's
# environment is consumed: by systemd (EnvironmentFile=, what the service gets)
# and by a deploy hook (bash). A legacy raw env file is normalised on deploy.
#
# Needs root and systemd; skips without them unless REQUIRE_SYSTEMD=1 (CI).
# Installs homeportd and writes under /opt/homeport, /etc/homeport: run it on
# a throwaway machine (a CI runner), never on a real box.
set -uo pipefail
cd "$(dirname "$0")/.."

if [[ $(id -u) != 0 ]] || ! command -v systemd-run >/dev/null; then
  [[ ${REQUIRE_SYSTEMD:-} == 1 ]] && { echo "needs root and systemd (REQUIRE_SYSTEMD=1)"; exit 1; }
  echo "skip: needs root and systemd"; exit 0
fi

fails=0
eq() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fails=$((fails + 1)); fi; }

HD=/usr/local/bin/homeportd
awk "/<<'HOMEPORTD_SCRIPT'/{f=1;next} /^HOMEPORTD_SCRIPT\$/{f=0} f" bootstrap/bootstrap.sh > /tmp/homeportd.new
install -m 755 /tmp/homeportd.new "$HD"
# shellcheck disable=SC1090
source "$HD"; set +e
id -u deploy >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin deploy
mkdir -p "$HOMEPORT_ETC" "$HOMEPORT_ROOT"

APP=envtest
"$HD" add "$APP" - / >/dev/null || { echo "add failed"; exit 1; }
trap '"$HD" remove "$APP" --yes >/dev/null 2>&1' EXIT
ENVF="$HOMEPORT_ROOT/$APP/shared/env"
# a release dir for the hook to cd into (no need to activate anything)
install -d "$HOMEPORT_ROOT/$APP/releases/r1"; printf '#!/bin/sh\n' > "$HOMEPORT_ROOT/$APP/releases/r1/bin"
ln -sfn releases/r1 "$HOMEPORT_ROOT/$APP/current"

as_service() { systemd-run --quiet --pipe --wait -p EnvironmentFile="$ENVF" /usr/bin/printenv "$1"; }
as_hook()    { run_deploy_hook "$APP" "printf %s \"\$$1\""; }

values=(
  'a\b'
  'C:\path\to\file'
  'tricky "value" with \ backslash'
  'p@ss w0rd!'
  '$HOME and `id` and $(id)'
  "it's"
  'a"b\c$d`e'
  'héllo wörld'
  '\\double'
)
i=0
for v in "${values[@]}"; do
  i=$((i + 1))
  printf 'V%d=%s\n' "$i" "$v" | "$HD" env "$APP" >/dev/null
  eq "service gets [$v] exactly" "$(as_service "V$i")" "$v"
  eq "hook gets    [$v] exactly" "$(as_hook "V$i")" "$v"
done
# .env quoting keeps working as it always did
printf '%s\n' 'Q1="quoted value"' "Q2='single \\x'" | "$HD" env "$APP" >/dev/null
eq "double-quoted .env value" "$(as_service Q1)" "quoted value"
eq "single-quoted .env value" "$(as_service Q2)" 'single \x'
eq "nothing a value contained was executed" "$(ls /tmp/pwned 2>/dev/null || echo none)" "none"

# a box upgraded from before canonical storage: raw lines, normalised on deploy
printf '%s\n' 'L1=legacy\path' 'L2="kept"' > "$ENVF"
eq "legacy raw value as systemd sees it BEFORE (the bug)" "$(as_service L1)" 'legacypath'
env_normalize "$APP"
eq "legacy value after normalising"  "$(as_service L1)" 'legacy\path'
eq "legacy quoted value unchanged"   "$(as_service L2)" 'kept'
eq "env file stays root:$APP 640"    "$(stat -c '%U:%G %a' "$ENVF")" "root:homeport-$APP 640"

if [[ $fails -gt 0 ]]; then echo "$fails env fidelity test(s) FAILED"; exit 1; fi
echo "all env fidelity tests passed (systemd $(systemctl --version | awk 'NR==1{print $2}'))"
