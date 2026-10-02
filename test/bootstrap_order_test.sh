#!/usr/bin/env bash
# The server bootstrap (bootstrap.sh's own main, not homeportd's) on a fresh
# cloud box: its first-boot package updates hold apt's lock for minutes, and
# root SSH is the only way back in until homeportd is installed. So:
#   - apt waits for the lock (DPkg::Lock::Timeout), set before the first apt-get;
#   - root login is disabled last, after homeportd is in - a failure anywhere
#     before leaves root, rather than locking everyone out of a half-set-up box.
set -euo pipefail
cd "$(dirname "$0")/.."
# the bootstrap's own main: the last one (homeportd's, embedded above, has one too)
start=$(grep -n '^main() {' bootstrap/bootstrap.sh | tail -1 | cut -d: -f1)
main=$(tail -n "+$start" bootstrap/bootstrap.sh | awk '{print} /^\}/{exit}')
fail=0
line() { grep -n -m1 -E -- "$1" <<<"$main" | cut -d: -f1 || true; }
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

lock=$(line 'DPkg::Lock::Timeout'); apt=$(line '^[[:space:]]+apt-get ')
[[ -n $lock && -n $apt && $lock -lt $apt ]] && ok "apt waits for the lock before the first apt-get" \
  || bad "apt waits for the lock before the first apt-get (lock at ${lock:-none}, first apt-get at ${apt:-none})"

harden=$(line 'setup_ssh_hardening'); last=$(line 'setup_dirs_and_sudo'); hd=$(line 'install_homeportd')
[[ -n $harden && -n $last && -n $hd && $harden -gt $last && $harden -gt $hd ]] && ok "root login is disabled last" \
  || bad "root login is disabled last (hardening at ${harden:-none}, homeportd at ${hd:-none}, sudo at ${last:-none})"
exit $fail
