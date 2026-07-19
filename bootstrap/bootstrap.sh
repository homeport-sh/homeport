#!/usr/bin/env bash
#
# homeport bootstrap — turn a fresh Ubuntu VPS into a hardened single-binary
# app host in one command.
#
# Run it one of two ways:
#
#   1. SSH in as root and paste:
#        curl -fsSL https://homeport.example/bootstrap.sh | bash
#
#   2. Paste this whole file into the "Cloud config / user data" box when
#      creating the server on Hetzner — the box hardens itself on first
#      boot and you never have to SSH in as root at all.
#
# What it does (idempotent — safe to re-run):
#   * creates a non-root `deploy` user with your SSH key
#   * firewall (ufw): only 22/80/443 open, SSH rate-limited
#   * SSH hardening: key-only auth, root login disabled
#   * fail2ban + automatic security upgrades
#   * installs Caddy (reverse proxy with automatic HTTPS)
#   * installs homeportd, the root-side deploy helper the homeport CLI talks to
#
set -euo pipefail

log()  { echo -e "\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33mWARN:\033[0m $*" >&2; }
die()  { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

setup_deploy_user() {
  if ! id -u deploy &>/dev/null; then
    log "Creating 'deploy' user"
    useradd --create-home --shell /bin/bash deploy
  fi
  install -d -o deploy -g deploy -m 700 /home/deploy/.ssh
  # Hetzner injects the SSH key you picked at creation into root's
  # authorized_keys — hand the same key(s) to the deploy user.
  if [[ -s /root/.ssh/authorized_keys ]]; then
    touch /home/deploy/.ssh/authorized_keys
    sort -u /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys \
      -o /home/deploy/.ssh/authorized_keys
    chown deploy:deploy /home/deploy/.ssh/authorized_keys
    chmod 600 /home/deploy/.ssh/authorized_keys
  fi
}

setup_firewall() {
  log "Configuring firewall (only 22, 80, 443 open)"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw limit OpenSSH >/dev/null     # allow + rate-limit brute force
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
}

setup_ssh_hardening() {
  if [[ ! -s /home/deploy/.ssh/authorized_keys ]]; then
    warn "deploy user has no SSH key — SKIPPING SSH hardening so you don't get locked out."
    warn "Add a public key to /home/deploy/.ssh/authorized_keys and re-run this script."
    return
  fi
  log "Hardening SSH (key-only auth, root login disabled)"
  # sshd uses the FIRST value it sees for each directive, and files in
  # sshd_config.d are read in glob order before the main config — the 00-
  # prefix makes this file win over cloud-init's 50-cloud-init.conf.
  cat > /etc/ssh/sshd_config.d/00-homeport.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
X11Forwarding no
MaxAuthTries 5
EOF
  if ! sshd -t 2>/dev/null; then
    rm -f /etc/ssh/sshd_config.d/00-homeport.conf
    die "sshd config test failed — hardening rolled back, nothing changed"
  fi
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
}

setup_fail2ban() {
  log "Enabling fail2ban (SSH brute-force protection)"
  cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
backend = systemd
EOF
  systemctl enable --now fail2ban >/dev/null
  systemctl restart fail2ban
}

setup_auto_upgrades() {
  log "Enabling automatic security upgrades"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

setup_sysctl() {
  log "Applying kernel hardening (sysctl)"
  cat > /etc/sysctl.d/99-homeport.conf <<'EOF'
# ptrace: stop one app user from reading another running app's memory
kernel.yama.ptrace_scope = 1
# hide kernel pointers / dmesg from unprivileged users (defeats infoleaks)
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
# network: reverse-path filter, ignore ICMP redirects, no source routing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
EOF
  # apply now; ignore keys the kernel/LSM doesn't expose (e.g. yama absent)
  sysctl --system >/dev/null 2>&1 || true
}

setup_caddy() {
  if ! command -v caddy >/dev/null; then
    log "Installing Caddy"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y -qq caddy >/dev/null
  fi
  mkdir -p /etc/caddy/homeport.d
  if ! grep -qs 'managed by homeport' /etc/caddy/Caddyfile; then
    [[ -f /etc/caddy/Caddyfile ]] && cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.pre-homeport
    cat > /etc/caddy/Caddyfile <<'EOF'
# managed by homeport — per-app configs live in /etc/caddy/homeport.d/
import /etc/caddy/homeport.d/*.caddy
EOF
  fi
  [[ -f /etc/caddy/homeport.d/00-homeport.caddy ]] \
    || echo "# homeport apps are added here by homeportd" > /etc/caddy/homeport.d/00-homeport.caddy
  systemctl enable --now caddy >/dev/null
  systemctl reload caddy 2>/dev/null || systemctl restart caddy
}

setup_dirs_and_sudo() {
  mkdir -p /opt/homeport /etc/homeport/apps
  # The deploy user may run exactly one privileged command: homeportd.
  # Every root-side mutation is centralized and input-validated there.
  cat > /etc/sudoers.d/homeport <<'EOF'
deploy ALL=(root) NOPASSWD: /usr/local/bin/homeportd
EOF
  chmod 440 /etc/sudoers.d/homeport
  visudo -cf /etc/sudoers.d/homeport >/dev/null || die "sudoers validation failed"
}

install_homeportd() {
  log "Installing homeportd (root-side deploy helper)"
  cat > /usr/local/bin/homeportd <<'HOMEPORTD_SCRIPT'
#!/usr/bin/env bash
# homeportd — root-side helper for homeport. Installed by bootstrap.sh.
# The deploy user may run exactly this script via sudo; every privileged
# mutation on the box goes through here and validates its inputs.
set -euo pipefail

HOMEPORTD_VERSION=0.1.0
HOMEPORTD_API=1

HOMEPORT_ROOT=/opt/homeport
HOMEPORT_ETC=/etc/homeport/apps
CADDY_DIR=/etc/caddy/homeport.d
BASE_PORT=8100

die() { echo "homeportd: $*" >&2; exit 1; }

valid_app()     { [[ ${1:-} =~ ^[a-z][a-z0-9-]{0,19}$ ]] || die "invalid app name: '${1:-}' (lowercase letters, digits, dashes, max 20 chars)"; }
valid_release() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$ ]] || die "invalid release id: '${1:-}'"; }
valid_domain()  { [[ ${1:-} =~ ^[a-z0-9]([a-z0-9.-]{0,250}[a-z0-9])?$ ]] || die "invalid domain: '${1:-}'"; }

load_app() {
  [[ -f "$HOMEPORT_ETC/$1/config" ]] || die "unknown app '$1' — register it first (the homeport CLI does this on deploy)"
  # config is root-owned and written only by homeportd — safe to source
  # shellcheck disable=SC1090
  source "$HOMEPORT_ETC/$1/config"
}

next_port() {
  local port=$BASE_PORT
  while grep -qs "^PORT=$port\$" "$HOMEPORT_ETC"/*/config 2>/dev/null; do
    port=$((port + 1))
  done
  echo "$port"
}

public_ip() {
  curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

swap_current() { # swap_current <app> <target>  (atomic symlink flip)
  ln -sfn "$2" "$HOMEPORT_ROOT/$1/.current.tmp"
  mv -Tf "$HOMEPORT_ROOT/$1/.current.tmp" "$HOMEPORT_ROOT/$1/current"
}

wait_healthy() { # uses $PORT and $HEALTH_PATH from load_app
  wait_healthy_port "$PORT"
}

# seconds for a duration like 30s/2m/1h (default 30 for empty/garbage). The
# split local declarations are deliberate: n/u must reference t AFTER it's set.
timeout_secs() {
  local t=${1:-30s}
  local n=${t%[smh]}
  local u=${t: -1}
  [[ $n =~ ^[0-9]+$ ]] || { echo 30; return; }
  case $u in
    s) echo "$n" ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    *) echo 30 ;;
  esac
}

wait_healthy_port() { # <port> — polls http://127.0.0.1:<port>$HEALTH_PATH
  # up to $HEALTH_TIMEOUT (default 30s), one probe every 0.5s
  local port=$1 i iters
  iters=$(( $(timeout_secs "${HEALTH_TIMEOUT:-30s}") * 2 ))
  (( iters < 1 )) && iters=1
  for (( i = 1; i <= iters; i++ )); do
    if curl -fs -o /dev/null --max-time 2 "http://127.0.0.1:$port$HEALTH_PATH" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# replica_base <public-port> — start of an app's private replica-port block.
# Each app gets 20 slots; block N starts at 10000 + N*20, never overlapping
# the public (8100+) or idle (9100+) ranges or another app's block.
replica_base() { echo $((10000 + ($1 - BASE_PORT) * 20)); }

# is_template — does the loaded app run as per-instance template units?
# True for fixed replicas>1 AND autoscale (even at 1 instance). Callers must
# have run load_app. This is what most runtime commands branch on, not a bare
# REPLICAS>1, because an autoscale app at min=1 is still a template instance.
is_template() { [[ ${REPLICAS:-1} -gt 1 || -n ${AUTOSCALE_MAX:-} ]]; }

# compute_limits <memory> <cpu> — echo the systemd cgroup limit lines for a
# unit (MemoryMax/MemoryHigh/CPUQuota). Shared by cmd_add and the blue/green
# activation, which regenerates a unit and must match the app's limits exactly.
compute_limits() {
  local memory=$1 cpu=$2 limits="" mem_num mem_suffix bytes
  if [[ -n $memory ]]; then
    # convert to bytes for the 90% calc so e.g. 1G doesn't integer-floor to 0G.
    mem_num=${memory%[KMG]} mem_suffix=${memory: -1}
    case $mem_suffix in
      K) bytes=$((mem_num * 1024)) ;;
      M) bytes=$((mem_num * 1024 * 1024)) ;;
      G) bytes=$((mem_num * 1024 * 1024 * 1024)) ;;
    esac
    limits+="MemoryMax=$memory"$'\n'
    limits+="MemoryHigh=$((bytes * 9 / 10))"$'\n'
  fi
  [[ -n $cpu ]] && limits+="CPUQuota=$cpu"$'\n'
  printf '%s' "$limits"
}

# emit_service_body <port-expr> — the shared [Service] block. Relies on
# bash dynamic scoping to read $app/$user/$limits/$HOMEPORT_ROOT from cmd_add.
emit_service_body() {
  # optional launch args (from RUN, set by cmd_add): substitute $PORT/$HOST
  # with this unit's port-expr ($1) and the loopback host. After substitution
  # RUN contains no "$" (validated), so the unquoted heredoc won't re-expand.
  local run_args=""
  if [[ -n ${RUN:-} ]]; then
    run_args=$RUN
    run_args=${run_args//\$\{PORT\}/$1}
    run_args=${run_args//\$PORT/$1}
    run_args=${run_args//\$\{HOST\}/127.0.0.1}
    run_args=${run_args//\$HOST/127.0.0.1}
  fi
  cat <<EOF
[Service]
User=$user
Group=$user
WorkingDirectory=$HOMEPORT_ROOT/$app/current
ExecStart=$HOMEPORT_ROOT/$app/current/bin${run_args:+ $run_args}
EnvironmentFile=-$HOMEPORT_ROOT/$app/shared/env
Environment=NODE_ENV=production
Environment=HOSTNAME=127.0.0.1
Environment=PORT=$1
Environment=NBC_RUNTIME_DIR=$HOMEPORT_ROOT/$app/shared/runtime
Environment=HOST=127.0.0.1
Environment=STATE_DIR=$HOMEPORT_ROOT/$app/shared
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
TasksMax=512
$limits
# single-binary apps need exactly one writable directory — lock down the rest
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$HOMEPORT_ROOT/$app/shared
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
EOF
  # Extra sandbox (default). Shrinks what a compromised binary — including a
  # third-party one — can reach. Skipped for `sandbox: relaxed`, which a binary
  # running its OWN sandbox needs: Chromium/Lightpanda use user namespaces +
  # seccomp, which RestrictNamespaces / SystemCallFilter would break. Note we
  # deliberately do NOT set MemoryDenyWriteExecute — it breaks JIT (Bun/Node).
  if [[ ${SANDBOX:-} != relaxed ]]; then
    cat <<'EOF'
CapabilityBoundingSet=
AmbientCapabilities=
RestrictNamespaces=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictRealtime=true
LockPersonality=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
ProcSubset=pid
PrivateDevices=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
EOF
  fi
}

_teardown_idle_units() { # remove socket/proxy when an app leaves idle mode
  local app=$1
  [[ -f "/etc/systemd/system/homeport-$app-proxy.socket" ]] || return 0
  systemctl disable --now "homeport-$app-proxy.socket" 2>/dev/null || true
  systemctl stop "homeport-$app-proxy.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/homeport-$app-proxy.socket" \
        "/etc/systemd/system/homeport-$app-proxy.service"
  systemctl daemon-reload
}

_teardown_autoscale_timer() { # remove the autoscaler when an app stops autoscaling
  local app=$1
  [[ -f "/etc/systemd/system/homeport-$app-autoscale.timer" ]] || return 0
  systemctl disable --now "homeport-$app-autoscale.timer" 2>/dev/null || true
  rm -f "/etc/systemd/system/homeport-$app-autoscale.timer" \
        "/etc/systemd/system/homeport-$app-autoscale.service"
  systemctl daemon-reload
}

# app_upstreams <port> <mode> <count> — echo the space-prefixed upstream list
# for an app (replica ports for a template, else the single loopback port).
app_upstreams() {
  local port=$1 mode=$2 count=${3:-1} upstreams="" rbase i
  if [[ $mode == template ]]; then
    rbase=$(replica_base "$port")
    for (( i = 1; i <= count; i++ )); do upstreams+=" 127.0.0.1:$((rbase + i))"; done
  else
    upstreams=" 127.0.0.1:$port"
  fi
  echo "$upstreams"
}

# emit_reverse_proxy <indent> <mode> <upstreams> — print a reverse_proxy
# directive indented by <indent> (a literal tab string), respecting the app's
# mode. Shared by a plain site block (write_caddy) and a gateway handle_path
# block (write_gateway).
emit_reverse_proxy() {
  local ind=$1 mode=$2 upstreams=$3
  case $mode in
    template)
      # lb_try_duration retries a request that hit a down/restarting replica on
      # a live upstream — what makes rolling deploys/scaling zero-downtime.
      printf '%sreverse_proxy%s {\n%s\tlb_policy least_conn\n%s\tlb_try_duration 4s\n%s\tlb_try_interval 250ms\n%s\tfail_duration 10s\n%s}\n' "$ind" "$upstreams" "$ind" "$ind" "$ind" "$ind" "$ind" ;;
    idle)
      # keepalive off so Caddy doesn't hold socket-proxyd open past idle.
      printf '%sreverse_proxy%s {\n%s\ttransport http {\n%s\t\tkeepalive off\n%s\t}\n%s}\n' "$ind" "$upstreams" "$ind" "$ind" "$ind" "$ind" ;;
    *)
      printf '%sreverse_proxy%s\n' "$ind" "$upstreams" ;;
  esac
}

# app_mode — echo the Caddy proxy mode for the loaded app's config vars.
app_mode() {
  if [[ ${REPLICAS:-1} -gt 1 || -n ${AUTOSCALE_MAX:-} ]]; then echo template
  elif [[ -n ${IDLE:-} ]]; then echo idle
  else echo plain; fi
}

# write_caddy <app> <domain> <port> <mode> <count> — (re)write an app's Caddy
# fragment (a whole-host site block). mode: template | idle | plain.
# Used by cmd_add and the autoscaler (which rewrites on every scale event).
write_caddy() {
  local app=$1 domain=$2 port=$3 mode=$4 count=${5:-1} upstreams
  upstreams=$(app_upstreams "$port" "$mode" "$count")
  { printf '%s {\n\tencode zstd gzip\n' "$domain"
    emit_reverse_proxy $'\t' "$mode" "$upstreams"
    printf '}\n'
  } > "$CADDY_DIR/$app.caddy"
}

# write_caddy_internal <app> <port> <count> — a load-balanced INTERNAL service:
# Caddy listens on loopback :port and balances the app's replica instances, so
# other apps on the box keep using 127.0.0.1:<port> while N instances serve
# behind it. No TLS, no public domain, no encode (it's all loopback).
write_caddy_internal() {
  local app=$1 port=$2 count=$3 upstreams
  upstreams=$(app_upstreams "$port" template "$count")
  { printf 'http://127.0.0.1:%s {\n' "$port"
    emit_reverse_proxy $'\t' template "$upstreams"
    printf '}\n'
  } > "$CADDY_DIR/$app.caddy"
}

# write_caddy_static <app> <domain> <spa> — Caddy serves a directory of files
# (no process). try_files gives clean URLs (/about → /about.html or /about/);
# an SPA also falls back to the app shell (200.html preferred, else index.html —
# both listed so Caddy picks whichever the build produced, no stat needed).
write_caddy_static() {
  local app=$1 domain=$2 spa=$3 fallback=""
  [[ $spa == 1 ]] && fallback=" /200.html /index.html"
  { printf '%s {\n' "$domain"
    printf '\tencode zstd gzip\n'
    printf '\troot * %s/%s/current\n' "$HOMEPORT_ROOT" "$app"
    printf '\ttry_files {path} {path}.html {path}/%s\n' "$fallback"
    printf '\tfile_server\n'
    printf '}\n'
  } > "$CADDY_DIR/$app.caddy"
}

# cmd_add_static <app> <domain> <spa> — register a static site: a Caddy
# file_server on its own domain, no systemd unit, no app user, no port bound.
cmd_add_static() {
  local app=$1 domain=$2 spa=${3:-}
  [[ $domain == - || -z $domain ]] && die "a static site needs a domain"
  valid_domain "$domain"
  [[ $spa == 1 ]] || spa=""
  # host-ownership conflict: the domain must be free (not another app's whole
  # host, not a gateway host) — mirrors the binary-app check.
  local _cfg _odom _oapp
  for _cfg in "$HOMEPORT_ETC"/*/config; do
    [[ -f $_cfg && $_cfg != "$HOMEPORT_ETC/$app/config" ]] || continue
    _odom=$(sed -n 's/^DOMAIN=//p' "$_cfg"); [[ $_odom == "$domain" ]] || continue
    _oapp=$(basename "$(dirname "$_cfg")")
    die "domain $domain is already used by app '$_oapp'"
  done

  local port keep=5 was_binary=0
  if [[ -f "$HOMEPORT_ETC/$app/config" ]]; then
    load_app "$app"; port=$PORT; keep=${KEEP:-5}
    [[ ${STATIC:-} == 1 ]] || was_binary=1   # switching a binary app → static
  else
    port=$(next_port)
  fi
  # if this app was a binary before, tear down its process bits
  if [[ $was_binary -eq 1 ]]; then
    systemctl disable --now "homeport-$app" 2>/dev/null || true
    _teardown_idle_units "$app"; _teardown_autoscale_timer "$app"
    rm -f "/etc/systemd/system/homeport-$app.service" "/etc/systemd/system/homeport-$app@.service"
    systemctl daemon-reload
    id -u "homeport-$app" &>/dev/null && userdel "homeport-$app" 2>/dev/null || true
  fi

  install -d -m 755 "$HOMEPORT_ROOT/$app"
  # releases/ is the deploy-writable upload target; no shared/ (a static site
  # has no process and no secrets).
  install -d -o deploy -g deploy -m 755 "$HOMEPORT_ROOT/$app/releases"
  mkdir -p "$HOMEPORT_ETC/$app"
  cat > "$HOMEPORT_ETC/$app/config" <<EOF
APP=$app
PORT=$port
DOMAIN=$domain
STATIC=1
SPA=$spa
KEEP=$keep
EOF
  write_caddy_static "$app" "$domain" "$spa"
  caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
    || die "generated Caddy config failed validation"
  systemctl reload caddy
  echo "app '$app' registered (static${spa:+, SPA}) -> https://$domain"
  echo "DNS: point an A record for $domain to $(public_ip) — TLS is automatic once it resolves"
}

# cmd_upload_static <app> <release> — extract a tar.gz of the site from stdin.
cmd_upload_static() {
  local app=${1:-} release=${2:-}
  valid_app "$app"; valid_release "$release"
  [[ -f "$HOMEPORT_ETC/$app/config" ]] || die "unknown app '$app' — register it first"
  local dir="$HOMEPORT_ROOT/$app/releases/$release"
  rm -rf "$dir"
  install -d -o deploy -g deploy -m 755 "$dir"
  # cap the compressed stream (2 GiB) so a runaway upload can't fill the disk;
  # GNU tar refuses '..' members by default, so extraction stays inside dir.
  head -c $((2 * 1024 * 1024 * 1024)) | tar -xzf - -C "$dir" --no-same-owner 2>/dev/null \
    || { rm -rf "$dir"; die "could not extract upload (not a .tar.gz?)"; }
  [[ -f "$dir/index.html" ]] || { rm -rf "$dir"; die "upload has no index.html at its root"; }
  echo "uploaded $release ($(du -sh "$dir" 2>/dev/null | cut -f1))"
}

# gateway_slug <domain> — filesystem-safe token for a shared-host fragment.
# printf (not echo) so a trailing newline doesn't become a trailing '-'.
gateway_slug() { printf %s "$1" | tr -c 'a-zA-Z0-9' '-'; }

# write_gateway <domain> — (re)generate the merged Caddy block for a host that
# has one or more path-mounted apps. Scans every app config sharing <domain>
# with a PATH_PREFIX and emits a handle_path per prefix (longest first, so a
# more specific prefix wins). Removes the fragment when no path-apps remain.
write_gateway() {
  local domain=$1 slug frag cfg
  slug=$(gateway_slug "$domain")
  frag="$CADDY_DIR/_gw_$slug.caddy"
  local -a rows=()
  for cfg in "$HOMEPORT_ETC"/*/config; do
    [[ -f $cfg ]] || continue
    local row
    row=$(
      # shellcheck disable=SC1090
      source "$cfg"
      [[ ${DOMAIN:-} == "$domain" && -n ${PATH_PREFIX:-} ]] || exit 1
      printf '%s\t%s\t%s' "$PATH_PREFIX" "$(app_mode)" "$(app_upstreams "$PORT" "$(app_mode)" "${REPLICAS:-1}")"
    ) || continue
    rows+=("$row")
  done
  if [[ ${#rows[@]} -eq 0 ]]; then
    rm -f "$frag"
    return 0
  fi
  # longest path prefix first — Caddy tries handle_path blocks in written order.
  local -a sorted
  mapfile -t sorted < <(printf '%s\n' "${rows[@]}" | awk -F'\t' '{ print length($1), $0 }' | sort -rn | cut -d' ' -f2-)
  {
    printf '%s {\n\tencode zstd gzip\n' "$domain"
    local r path mode ups
    for r in "${sorted[@]}"; do
      IFS=$'\t' read -r path mode ups <<<"$r"
      printf '\thandle_path %s/* {\n' "$path"
      emit_reverse_proxy $'\t\t' "$mode" "$ups"
      printf '\t}\n'
    done
    printf '\thandle {\n\t\trespond "no route for this path" 404\n\t}\n'
    printf '}\n'
  } > "$frag"
}

prune_releases() { # keep the newest $KEEP releases, never the live one
  local app=$1 current
  current=$(readlink "$HOMEPORT_ROOT/$app/current" 2>/dev/null || true)
  current=${current#releases/}
  local -a releases
  mapfile -t releases < <(ls -1 "$HOMEPORT_ROOT/$app/releases" | sort)
  local n=${#releases[@]} keep=${KEEP:-5} i
  (( n > keep )) || return 0
  for (( i = 0; i < n - keep; i++ )); do
    [[ ${releases[$i]} == "$current" ]] && continue
    rm -rf "$HOMEPORT_ROOT/$app/releases/${releases[$i]:?}"
  done
}

cmd_add() {
  local app=${1:-} domain=${2:-} health=${3:-/} memory=${4:-} cpu=${5:-} idle=${6:-} idle_timeout=${7:-} replicas=${8:-} autoscale=${9:-} run_b64=${10:-} release_b64=${11:-} post_release_b64=${12:-} path=${13:-} sandbox=${14:-} strategy=${15:-} health_timeout=${16:-} static=${17:-} spa=${18:-}
  valid_app "$app"
  # "-" means unset (positional placeholder from the CLI)
  [[ $domain == - ]] && domain=""
  [[ $path == - ]] && path=""
  # static sites are a wholly different shape (Caddy file_server, no process) —
  # handle them in their own function, leaving the binary-app path below untouched.
  [[ $static == 1 ]] && { cmd_add_static "$app" "$domain" "$spa"; return; }
  [[ $sandbox == - ]] && sandbox=""
  [[ $strategy == - ]] && strategy=""
  [[ $health_timeout == - ]] && health_timeout=""
  [[ -z $health_timeout || $health_timeout =~ ^[0-9]+[smh]$ ]] || die "health timeout must be a number with s/m/h suffix (e.g. 30s, 2m)"
  [[ -z $sandbox || $sandbox == strict || $sandbox == relaxed ]] || die "sandbox must be 'strict' (default) or 'relaxed'"
  [[ -z $strategy || $strategy == blue-green || $strategy == recreate ]] || die "strategy must be 'blue-green' (default) or 'recreate'"
  [[ $memory == - ]] && memory=""
  [[ $cpu == - ]] && cpu=""
  [[ $idle == - ]] && idle=""
  [[ $idle_timeout == - ]] && idle_timeout=""
  [[ $replicas == - || -z $replicas ]] && replicas=1
  [[ $autoscale == - ]] && autoscale=""
  [[ $run_b64 == - ]] && run_b64=""
  [[ $release_b64 == - ]] && release_b64=""
  [[ $post_release_b64 == - ]] && post_release_b64=""
  [[ -z $release_b64 ]] || printf %s "$release_b64" | base64 -d >/dev/null 2>&1 || die "release: invalid encoding"
  [[ -z $post_release_b64 ]] || printf %s "$post_release_b64" | base64 -d >/dev/null 2>&1 || die "post_release: invalid encoding"

  # run: optional launch args for the binary (base64 to survive spaces).
  # exec (no shell), only $PORT/$HOST substituted — validated to block
  # newlines, %, and shell metacharacters.
  local RUN=""
  if [[ -n $run_b64 ]]; then
    RUN=$(printf %s "$run_b64" | base64 -d 2>/dev/null) || die "run: invalid encoding"
    [[ $RUN != *$'\n'* ]] || die "run must be a single line"
    local _rre='^[A-Za-z0-9 ._:/=@,+${}-]*$'
    [[ $RUN =~ $_rre ]] || die "run has unsupported characters"
    local _chk=$RUN
    _chk=${_chk//\$\{PORT\}/}; _chk=${_chk//\$PORT/}
    _chk=${_chk//\$\{HOST\}/}; _chk=${_chk//\$HOST/}
    [[ $_chk != *'$'* ]] || die "run may only reference \$PORT and \$HOST"
  fi
  # No domain => internal app: bound to 127.0.0.1, reachable only from other
  # apps on the box or through `homeport tunnel`. No Caddy fragment, no TLS,
  # nothing on 80/443.
  [[ -z $domain ]] || valid_domain "$domain"
  # path: mount this app under a shared domain (a gateway host). Needs a domain,
  # can't be internal, must be a clean prefix.
  if [[ -n $path ]]; then
    [[ -n $domain ]] || die "path needs a domain (path mounts an app under a shared host)"
    [[ $path =~ ^/[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]] || die "invalid path '$path' (leading slash, no trailing slash, no spaces — e.g. /geo-api)"
  fi
  # host-ownership conflicts: a domain is either a single-app host or a gateway
  # host (every app on it path-mounted), never both — and two apps can't claim
  # the same prefix. Read siblings with sed (not source) to avoid clobbering.
  if [[ -n $domain ]]; then
    local _cfg _odom _opath _oapp
    for _cfg in "$HOMEPORT_ETC"/*/config; do
      [[ -f $_cfg && $_cfg != "$HOMEPORT_ETC/$app/config" ]] || continue
      _odom=$(sed -n 's/^DOMAIN=//p' "$_cfg"); [[ $_odom == "$domain" ]] || continue
      _opath=$(sed -n 's/^PATH_PREFIX=//p' "$_cfg"); _oapp=$(basename "$(dirname "$_cfg")")
      if [[ -n $path ]]; then
        [[ -z $_opath ]] && die "domain $domain is already a single-app host (app '$_oapp') — can't path-mount onto it"
        [[ $_opath == "$path" ]] && die "path $path on $domain is already used by app '$_oapp'"
      else
        [[ -n $_opath ]] && die "domain $domain is a gateway host (app '$_oapp' mounts $_opath) — give this app a path: too"
      fi
    done
  fi
  # anchored + charset-locked: HEALTH_PATH is written to config and source'd as
  # root, so an un-validated value here is arbitrary root command substitution.
  [[ $health =~ ^/[A-Za-z0-9._/-]*$ ]] || die "health path must start with / and contain only [A-Za-z0-9._/-]"
  [[ -z $memory || $memory =~ ^[0-9]+[KMG]$ ]] || die "invalid memory limit: '$memory' (e.g. 512M, 1G)"
  [[ -z $cpu || $cpu =~ ^[0-9]+%$ ]] || die "invalid cpu limit: '$cpu' (e.g. 150%)"
  [[ -z $idle || $idle == true ]] || die "idle must be 'true' or unset"
  [[ -z $idle_timeout || $idle_timeout =~ ^[0-9]+[smh]$ ]] || die "invalid idle_timeout: '$idle_timeout' (e.g. 300s, 5m)"
  [[ -n $idle ]] && idle_timeout=${idle_timeout:-300s}
  [[ $replicas =~ ^[0-9]+$ && $replicas -ge 1 && $replicas -le 20 ]] || die "replicas must be 1-20 (got '$replicas')"
  [[ $replicas -gt 1 && -n $idle ]] && die "replicas and idle are mutually exclusive (idle is 0<->1, replicas is 1<->N)"

  # autoscale = "min:max:target" — dynamic replica count driven by a systemd
  # timer. Parsed here into AUTOSCALE_* used throughout cmd_add.
  local AUTOSCALE_MIN="" AUTOSCALE_MAX="" AUTOSCALE_TARGET="" as_min="" as_max="" as_target=""
  if [[ -n $autoscale ]]; then
    [[ $autoscale =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]] || die "autoscale must be min:max:target (got '$autoscale')"
    AUTOSCALE_MIN=${BASH_REMATCH[1]} AUTOSCALE_MAX=${BASH_REMATCH[2]} AUTOSCALE_TARGET=${BASH_REMATCH[3]}
    as_min=$AUTOSCALE_MIN as_max=$AUTOSCALE_MAX as_target=$AUTOSCALE_TARGET
    [[ -z $idle ]] || die "autoscale and idle are mutually exclusive"
    (( AUTOSCALE_MIN >= 1 && AUTOSCALE_MAX <= 20 && AUTOSCALE_MIN <= AUTOSCALE_MAX )) || die "autoscale needs 1<=min<=max<=20"
    (( AUTOSCALE_TARGET >= 1 && AUTOSCALE_TARGET <= 100 )) || die "autoscale target must be 1-100"
    # start at min unless the app already has more instances running
    replicas=$AUTOSCALE_MIN
    # (plain `if`, not `&&` chains: a false final [[ ]] as the group's last
    # command would trip set -e and abort the whole add)
    if [[ -f "$HOMEPORT_ETC/$app/config" ]]; then
      local _r; _r=$(grep -m1 '^REPLICAS=' "$HOMEPORT_ETC/$app/config" | cut -d= -f2)
      if [[ $_r =~ ^[0-9]+$ && $_r -ge $AUTOSCALE_MIN && $_r -le $AUTOSCALE_MAX ]]; then replicas=$_r; fi
    fi
  fi
  # template unit (per-instance) is used for fixed replicas>1 AND autoscale
  local use_template=0
  [[ $replicas -gt 1 || -n $autoscale ]] && use_template=1
  local user="homeport-$app" port keep=5 old_replicas=1 old_domain="" old_path=""

  if [[ -f "$HOMEPORT_ETC/$app/config" ]]; then
    load_app "$app"
    port=$PORT keep=$KEEP old_replicas=${REPLICAS:-1}
    old_domain=${DOMAIN:-} old_path=${PATH_PREFIX:-}
  else
    port=$(next_port)
  fi
  # load_app (above) may have sourced the OLD config over freshly-parsed values
  # (SANDBOX, and the AUTOSCALE_* when switching an app INTO autoscale) — restore
  # the values for THIS add so they get written and take effect.
  local SANDBOX=$sandbox STRATEGY=$strategy
  AUTOSCALE_MIN=$as_min AUTOSCALE_MAX=$as_max AUTOSCALE_TARGET=$as_target
  # idle (scale-to-zero) apps bind a private port; systemd holds the public
  # port and starts the app on first connection. +1000 keeps the two ranges
  # from colliding (public 8100.., internal 9100..).
  local internal_port=$port
  [[ -n $idle ]] && internal_port=$((port + 1000))

  mkdir -p "$HOMEPORT_ETC/$app"
  cat > "$HOMEPORT_ETC/$app/config" <<EOF
APP=$app
PORT=$port
DOMAIN=$domain
HEALTH_PATH=$health
KEEP=$keep
MEMORY=$memory
CPU=$cpu
IDLE=$idle
IDLE_TIMEOUT=$idle_timeout
REPLICAS=$replicas
AUTOSCALE_MIN=$AUTOSCALE_MIN
AUTOSCALE_MAX=$AUTOSCALE_MAX
AUTOSCALE_TARGET=$AUTOSCALE_TARGET
RUN_B64=$run_b64
RELEASE_B64=$release_b64
POST_RELEASE_B64=$post_release_b64
PATH_PREFIX=$path
SANDBOX=$sandbox
STRATEGY=$strategy
HEALTH_TIMEOUT=$health_timeout
EOF

  # cgroup limits — the same kernel mechanism as docker --memory/--cpus.
  # MemoryHigh (90% of the cap) throttles before MemoryMax OOM-kills.
  local limits; limits=$(compute_limits "$memory" "$cpu")

  id -u "$user" &>/dev/null \
    || useradd --system --home-dir "$HOMEPORT_ROOT/$app" --no-create-home --shell /usr/sbin/nologin "$user"

  install -d -m 755 "$HOMEPORT_ROOT/$app"
  # releases/ is writable by the deploy user (scp target); binaries are
  # chowned to root on activate so the app user can't modify what it runs.
  install -d -o deploy -g deploy -m 755 "$HOMEPORT_ROOT/$app/releases"
  install -d -o "$user" -g "$user" -m 750 "$HOMEPORT_ROOT/$app/shared" "$HOMEPORT_ROOT/$app/shared/runtime"
  touch "$HOMEPORT_ROOT/$app/shared/env"
  chown root:"$user" "$HOMEPORT_ROOT/$app/shared/env"
  chmod 640 "$HOMEPORT_ROOT/$app/shared/env"

  # --- write the app's systemd unit(s) for its mode ---
  local caddy_upstreams=""
  if [[ $use_template -eq 1 ]]; then
    # Template unit (fixed replicas>1 OR autoscale): one instance per private
    # port, Caddy load-balances. Instances are named by their port so the
    # unit uses PORT=%i with no arithmetic. Started rolling in activate.
    local rbase i p
    rbase=$(replica_base "$port")
    { echo "[Unit]"
      echo "Description=homeport app: $app (replica %i)"
      echo "After=network-online.target"
      echo "Wants=network-online.target"
      echo
      emit_service_body '%i'
      echo
      echo "[Install]"
      echo "WantedBy=multi-user.target"
    } > "/etc/systemd/system/homeport-$app@.service"
    # leaving single-instance (or idle) mode: STOP the old service before its
    # unit file goes — otherwise the process runs on as an orphan.
    if [[ -f "/etc/systemd/system/homeport-$app.service" ]]; then
      systemctl disable --now "homeport-$app" 2>/dev/null || true
      rm -f "/etc/systemd/system/homeport-$app.service"
    fi
    _teardown_idle_units "$app"
    systemctl daemon-reload
    for (( i = 1; i <= replicas; i++ )); do
      p=$((rbase + i))
      systemctl enable "homeport-$app@$p" >/dev/null 2>&1 || true
      caddy_upstreams+=" 127.0.0.1:$p"
    done
    # scale-down: retire instances beyond the new count
    for (( i = replicas + 1; i <= old_replicas; i++ )); do
      systemctl disable --now "homeport-$app@$((rbase + i))" 2>/dev/null || true
    done
    # autoscale: a systemd timer nudges the count between min and max; a fixed
    # replica app has no timer (tear one down if the app used to autoscale).
    if [[ -n $autoscale ]]; then
      cat > "/etc/systemd/system/homeport-$app-autoscale.service" <<EOF
[Unit]
Description=homeport autoscaler: $app
[Service]
Type=oneshot
ExecStart=/usr/local/bin/homeportd autoscale $app
EOF
      cat > "/etc/systemd/system/homeport-$app-autoscale.timer" <<EOF
[Unit]
Description=homeport autoscaler tick: $app
[Timer]
OnBootSec=45s
OnUnitActiveSec=20s
[Install]
WantedBy=timers.target
EOF
      systemctl daemon-reload
      systemctl enable --now "homeport-$app-autoscale.timer" >/dev/null 2>&1 || true
    else
      _teardown_autoscale_timer "$app"
    fi
  else
    # Single instance. Idle apps bind a private port (+1000) and are pulled
    # up by their socket-proxy; always-on apps bind the public port directly.
    local idle_unit="" install_sec=$'[Install]\nWantedBy=multi-user.target'
    if [[ -n $idle ]]; then
      # StopWhenUnneeded, not PartOf: when socket-proxyd self-exits on
      # --exit-idle-time (a clean exit, not a `systemctl stop`), PartOf does
      # NOT propagate — the app would linger. StopWhenUnneeded stops the app
      # the moment nothing Requires it (i.e. the proxy is gone). Verified on
      # the first live 0.6.1 box, where PartOf left the app running forever.
      idle_unit="StopWhenUnneeded=true"
      install_sec=""
    fi
    # leaving replica/autoscale mode: stop every old instance before the
    # template goes, and remove the autoscaler timer.
    if [[ $old_replicas -gt 1 ]]; then
      local orb oi
      orb=$(replica_base "$port")
      for (( oi = 1; oi <= old_replicas; oi++ )); do
        systemctl disable --now "homeport-$app@$((orb + oi))" 2>/dev/null || true
      done
    fi
    _teardown_autoscale_timer "$app"
    rm -f "/etc/systemd/system/homeport-$app@.service"
    { echo "[Unit]"
      echo "Description=homeport app: $app"
      echo "After=network-online.target"
      echo "Wants=network-online.target"
      [[ -n $idle_unit ]] && echo "$idle_unit"
      echo
      emit_service_body "$internal_port"
      echo
      [[ -n $install_sec ]] && echo "$install_sec"
    } > "/etc/systemd/system/homeport-$app.service"

    if [[ -n $idle ]]; then
      # Scale-to-zero: systemd holds the public port and starts the app on
      # first connection. systemd-socket-proxyd bridges to the private port
      # and exits after $idle_timeout; the app is StopWhenUnneeded so it stops too.
      cat > "/etc/systemd/system/homeport-$app-proxy.socket" <<EOF
[Unit]
Description=homeport socket: $app (scale-to-zero)

[Socket]
ListenStream=127.0.0.1:$port

[Install]
WantedBy=sockets.target
EOF
      cat > "/etc/systemd/system/homeport-$app-proxy.service" <<EOF
[Unit]
Description=homeport proxy: $app
Requires=homeport-$app.service
After=homeport-$app.service

[Service]
ExecStart=/usr/lib/systemd/systemd-socket-proxyd --exit-idle-time=$idle_timeout 127.0.0.1:$internal_port
NoNewPrivileges=true
EOF
      systemctl daemon-reload
      systemctl disable --now "homeport-$app" 2>/dev/null || true
      systemctl enable --now "homeport-$app-proxy.socket" >/dev/null 2>&1 || true
    else
      systemctl daemon-reload
      systemctl enable "homeport-$app" >/dev/null 2>&1 || true
      _teardown_idle_units "$app"
    fi
    caddy_upstreams=" 127.0.0.1:$port"
  fi

  # --- Caddy routing ---
  local wrote_caddy=0
  if [[ -n $domain && -n $path ]]; then
    # path-mounted: contributes a handle_path to the shared host's gateway
    # block instead of owning a whole-host site block.
    rm -f "$CADDY_DIR/$app.caddy"
    write_gateway "$domain"; wrote_caddy=1
  elif [[ -n $domain ]]; then
    local cmode=plain
    [[ $use_template -eq 1 ]] && cmode=template
    [[ -n $idle ]] && cmode=idle
    write_caddy "$app" "$domain" "$port" "$cmode" "$replicas"; wrote_caddy=1
  elif [[ $use_template -eq 1 ]]; then
    # internal + replicas/autoscale: Caddy load-balances on loopback :port so
    # consumers keep using 127.0.0.1:<port> while N instances serve behind it.
    write_caddy_internal "$app" "$port" "$replicas"; wrote_caddy=1
  else
    # single internal instance binds :port directly — no Caddy fragment.
    rm -f "$CADDY_DIR/$app.caddy"
  fi

  # If this app used to be path-mounted on a host it no longer contributes to
  # (domain changed, path changed, or it went internal), regenerate that host's
  # gateway to drop the stale prefix. Must precede validation, or a leftover
  # gateway block could collide with a new whole-host block for the same domain.
  if [[ -n $old_path && ( $old_domain != "$domain" || $path != "$old_path" ) ]]; then
    write_gateway "$old_domain"; wrote_caddy=1
  fi

  if [[ $wrote_caddy -eq 1 ]]; then
    caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
      || die "generated Caddy config failed validation"
    systemctl reload caddy
  elif [[ -n $old_domain ]]; then
    # tore down a public/gateway fragment on the way to a plain internal app
    systemctl reload caddy 2>/dev/null || true
  fi

  local rmsg=""
  [[ -n $autoscale ]] && rmsg=" · autoscale $AUTOSCALE_MIN-$AUTOSCALE_MAX @ ${AUTOSCALE_TARGET}%"
  [[ -z $autoscale && $replicas -gt 1 ]] && rmsg=" · $replicas replicas"
  if [[ -n $domain ]]; then
    echo "app '$app' registered: https://$domain$path -> 127.0.0.1:$port$rmsg"
    echo "DNS: point an A record for $domain to $(public_ip) — TLS is automatic once it resolves"
  elif [[ $use_template -eq 1 ]]; then
    echo "app '$app' registered (internal, load-balanced) -> 127.0.0.1:$port$rmsg"
    echo "reach it from other apps at 127.0.0.1:$port, or with: homeport tunnel"
  else
    echo "app '$app' registered (internal) -> 127.0.0.1:$port"
    echo "not exposed publicly — reach it with: homeport tunnel"
  fi
}

# cmd_autoscale <app> — one autoscaler tick, run by the app's systemd timer.
# Reads per-instance CPU% over the interval and nudges the running replica
# count between AUTOSCALE_MIN and AUTOSCALE_MAX, with hysteresis + a cooldown
# so it can't flap. Rewrites the Caddy upstream list on every change.
cmd_autoscale() {
  local app=${1:-}
  valid_app "$app"; load_app "$app"
  [[ -n ${AUTOSCALE_MAX:-} ]] || return 0     # not an autoscale app
  local rbase; rbase=$(replica_base "$PORT")

  # current running instance count (instances are contiguous 1..n)
  local n=0 i
  for (( i = 1; i <= AUTOSCALE_MAX; i++ )); do
    systemctl is-active --quiet "homeport-$app@$((rbase + i))" || break
    n=$i
  done
  (( n < 1 )) && n=${REPLICAS:-$AUTOSCALE_MIN}

  # total CPU-nanoseconds consumed across the running instances
  local cpu_now=0 v
  for (( i = 1; i <= n; i++ )); do
    v=$(systemctl show "homeport-$app@$((rbase + i))" --property=CPUUsageNSec --value 2>/dev/null)
    [[ $v =~ ^[0-9]+$ ]] && cpu_now=$((cpu_now + v))
  done
  local now_ns; now_ns=$(date +%s%N)

  # load the previous reading; first tick just records and returns (no delta)
  local state="$HOMEPORT_ROOT/$app/.autoscale" prev_cpu=0 prev_ns=0 last_scale=0
  if [[ -f $state ]]; then
    # shellcheck disable=SC1090
    source "$state"; prev_cpu=${AS_CPU:-0} prev_ns=${AS_NS:-0} last_scale=${AS_LAST_SCALE:-0}
  fi
  local nowsec=$((now_ns / 1000000000))
  if (( prev_ns == 0 || now_ns <= prev_ns )); then
    # first tick — record baseline, no measurable %% yet
    printf 'AS_CPU=%s\nAS_NS=%s\nAS_LAST_SCALE=%s\nAS_CPU_PCT=\nAS_TICK=%s\n' \
      "$cpu_now" "$now_ns" "$last_scale" "$nowsec" > "$state"
    return 0
  fi

  # per-instance CPU% = (Δcpu_ns / Δwall_ns) / n * 100
  local dcpu=$((cpu_now - prev_cpu)) dt=$((now_ns - prev_ns))
  (( dcpu < 0 )) && dcpu=0
  local pct=$(( dcpu * 100 / (dt * n) ))
  # record the reading so `status` can show current-vs-target (like HPA)
  printf 'AS_CPU=%s\nAS_NS=%s\nAS_LAST_SCALE=%s\nAS_CPU_PCT=%s\nAS_TICK=%s\n' \
    "$cpu_now" "$now_ns" "$last_scale" "$pct" "$nowsec" > "$state"

  # cooldown: no second scale within 60s of the last one
  (( $((now_ns / 1000000000)) - last_scale < 60 )) && return 0

  local target=$n
  if (( pct > AUTOSCALE_TARGET && n < AUTOSCALE_MAX )); then
    target=$((n + 1))
  elif (( pct < AUTOSCALE_TARGET / 2 && n > AUTOSCALE_MIN )); then
    target=$((n - 1))         # scale down only well under target (hysteresis)
  fi
  (( target == n )) && return 0

  if (( target > n )); then
    local p=$((rbase + target))
    systemctl enable --now "homeport-$app@$p" >/dev/null 2>&1
    if ! wait_healthy_port "$p"; then
      systemctl disable --now "homeport-$app@$p" 2>/dev/null || true
      return 0                # new instance unhealthy — abort this tick
    fi
  else
    systemctl disable --now "homeport-$app@$((rbase + n))" 2>/dev/null || true
  fi

  sed -i "s/^REPLICAS=.*/REPLICAS=$target/" "$HOMEPORT_ETC/$app/config"
  # rewrite this app's upstreams at the new replica count — a path-mounted app
  # lives in its host's gateway block, a public one in its own site block, an
  # internal one in a loopback load-balancer block.
  if [[ -n ${PATH_PREFIX:-} ]]; then
    write_gateway "$DOMAIN"
  elif [[ -n ${DOMAIN:-} ]]; then
    write_caddy "$app" "$DOMAIN" "$PORT" template "$target"
  else
    write_caddy_internal "$app" "$PORT" "$target"
  fi
  systemctl reload caddy 2>/dev/null || true
  sed -i "s/^AS_LAST_SCALE=.*/AS_LAST_SCALE=$((now_ns / 1000000000))/" "$state"
  echo "autoscale $app: $n -> $target replicas (cpu ${pct}% / target ${AUTOSCALE_TARGET}%)"
}

restart_app() { # restart respecting scale-to-zero (uses $IDLE from load_app)
  local app=$1
  if [[ -n ${IDLE:-} ]]; then
    # stop the running instance so the new binary loads on the next wake;
    # keep the socket listening. wait_healthy's request wakes it fresh.
    systemctl stop "homeport-$app-proxy.service" "homeport-$app.service" 2>/dev/null || true
    systemctl start "homeport-$app-proxy.socket" 2>/dev/null || true
  else
    systemctl restart "homeport-$app"
  fi
}

rolling_restart() { # <app> — restart replicas one at a time, health-checking
  # each before the next. Caddy keeps serving from the others (fail_duration
  # pulls the restarting one out), so there's no downtime. Uses $PORT/$REPLICAS.
  local app=$1 rbase i p
  rbase=$(replica_base "$PORT")
  for (( i = 1; i <= ${REPLICAS:-1}; i++ )); do
    p=$((rbase + i))
    systemctl restart "homeport-$app@$p"
    if ! wait_healthy_port "$p"; then
      echo "--- replica $i (:$p) last 20 log lines ---" >&2
      journalctl -u "homeport-$app@$p" -n 20 --no-pager >&2 || true
      return 1
    fi
  done
  return 0
}

_bg_teardown() { # remove the transient blue/green green unit
  local app=$1
  systemctl stop "homeport-$app-green.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/homeport-$app-green.service"
  systemctl daemon-reload
}

# bluegreen_restart <app> — zero-downtime activation for a single-instance
# PUBLIC (domain, non-path, non-idle) app. The old instance (blue) keeps serving
# on $PORT while the NEW release starts on a private green port; once green is
# healthy, Caddy is flipped to it, blue is restarted onto the new release behind
# green's cover, then traffic flips back and green is retired. The steady state
# is unchanged (plain service on $PORT), so status/tunnel/remove are untouched.
# Returns non-zero WITHOUT disrupting blue if the new release is unhealthy.
bluegreen_restart() {
  local app=$1
  local green; green=$(( $(replica_base "$PORT") + 1 ))   # in the app's own free replica block
  # reconstruct emit_service_body's scope from the loaded config
  local user="homeport-$app" SANDBOX="${SANDBOX:-}" RUN="" limits
  [[ -n ${RUN_B64:-} && $RUN_B64 != - ]] && RUN=$(printf %s "$RUN_B64" | base64 -d 2>/dev/null)
  limits=$(compute_limits "${MEMORY:-}" "${CPU:-}")
  # 1. start GREEN (new release, already at current/) on the green port
  { echo "[Unit]"
    echo "Description=homeport blue/green: $app (green)"
    echo "After=network-online.target"; echo "Wants=network-online.target"; echo
    emit_service_body "$green"
  } > "/etc/systemd/system/homeport-$app-green.service"
  systemctl daemon-reload
  if ! systemctl start "homeport-$app-green.service" 2>/dev/null || ! wait_healthy_port "$green"; then
    echo "--- blue/green: new release (:$green) failed health, last 20 log lines ---" >&2
    journalctl -u "homeport-$app-green.service" -n 20 --no-pager >&2 || true
    _bg_teardown "$app"          # blue never lost traffic — caller reverts current
    return 1
  fi
  # 2. shift live traffic to green
  write_caddy "$app" "$DOMAIN" "$green" plain 1
  systemctl reload caddy
  # 3. bring blue onto the new release behind green's cover
  systemctl restart "homeport-$app"
  if ! wait_healthy_port "$PORT"; then
    # pathological (green on the same binary is healthy): restore Caddy to blue
    # and retire green so the caller's revert path finds a consistent state.
    write_caddy "$app" "$DOMAIN" "$PORT" plain 1; systemctl reload caddy
    _bg_teardown "$app"
    return 1
  fi
  # 4. shift traffic back to blue (canonical port) and retire green
  write_caddy "$app" "$DOMAIN" "$PORT" plain 1
  systemctl reload caddy
  _bg_teardown "$app"
  return 0
}

# restart+health for a whole app, respecting its mode. Returns 0 if healthy.
activate_and_check() {
  local app=$1
  if is_template; then
    rolling_restart "$app"
  elif [[ -n ${DOMAIN:-} && -z ${PATH_PREFIX:-} && -z ${IDLE:-} && ${STRATEGY:-blue-green} != recreate ]]; then
    # single-instance public app: blue/green, zero-downtime by default
    bluegreen_restart "$app"
  else
    # recreate strategy, or internal / path-mounted / idle single-instance
    restart_app "$app"
    wait_healthy
  fi
}

# run_deploy_hook <app> <command> [with_port] — run a deploy hook (release: or
# post_release:) on the box as the app user, with the app's env, against the
# release symlinked at current/. Returns the command's exit status. Pass a
# non-empty with_port to also export PORT (the post-hook can reach the now-live
# app at $HOST:$PORT; the pre-hook gets no PORT — nothing is listening yet).
run_deploy_hook() {
  local app=$1 cmd=$2 with_port=${3:-} user="homeport-$app"
  local dir="$HOMEPORT_ROOT/$app/current" envf="$HOMEPORT_ROOT/$app/shared/env"
  # the same env the service gets: app secrets from the env file (DATABASE_URL,
  # …) plus STATE_DIR so an embedded SQLite lives beside the running app's copy.
  local script="export STATE_DIR='$HOMEPORT_ROOT/$app/shared'"
  script+=" NBC_RUNTIME_DIR='$HOMEPORT_ROOT/$app/shared/runtime'"
  script+=" NODE_ENV=production HOST=127.0.0.1"
  [[ -n $with_port ]] && script+=" PORT=$PORT"
  script+="; set -a; [ -f '$envf' ] && . '$envf'; set +a"
  script+="; cd '$dir' || exit 1; $cmd"
  # binary is root-owned (app user can exec, not modify); the hook runs as the
  # unprivileged app user, so it can't reach beyond the app's own data.
  sudo -u "$user" -H bash -c "$script"
}

cmd_upload() { # <app> <release> — receive the binary on stdin into a release dir.
  # Replaces the old raw `mkdir` + `scp`, so every privileged step goes through
  # homeportd (and a scoped CI key can only reach it via ci-gate).
  local app=${1:-} release=${2:-}
  valid_app "$app"; valid_release "$release"
  [[ -f "$HOMEPORT_ETC/$app/config" ]] || die "unknown app '$app' — register it first"
  local dir="$HOMEPORT_ROOT/$app/releases/$release"
  install -d -o deploy -g deploy -m 755 "$HOMEPORT_ROOT/$app/releases" "$dir"
  # releases/ is deploy-writable, so a full deploy key could pre-plant bin as a
  # symlink to a root path; rm first so the '>' write can't follow it.
  rm -f "$dir/bin"
  # stream stdin to bin with a hard size ceiling (a runaway upload can't fill disk)
  local max=$((1024 * 1024 * 1024)) size # 1 GiB
  head -c $((max + 1)) > "$dir/bin"
  size=$(wc -c < "$dir/bin")
  (( size > max )) && { rm -rf "$dir"; die "upload exceeds ${max} bytes"; }
  (( size > 0 )) || { rm -rf "$dir"; die "upload was empty"; }
  chmod 755 "$dir/bin"
  echo "uploaded $release ($size bytes)"
}

# cmd_ci_gate <app> — the SSH forced command for a per-app-scoped CI key. sshd
# runs THIS instead of whatever the client asked for; the client's request is in
# $SSH_ORIGINAL_COMMAND. We permit only an allow-listed homeportd verb targeting
# THIS app — never remove/self-update/key-add, another app, or an interactive
# shell. Runs as root (via sudo in the authorized_keys line); homeportd
# re-validates every argument, so re-exec'ing the client's tokens is safe.
# ci_gate_decision <app> <orig> — pure scoped-key policy. Echoes "allow <off>"
# (argv index where the homeportd verb starts) or "deny <reason>". No exec/die,
# so the security policy is unit-testable. Word-splitting is safe: every token
# the CLI sends is whitespace-free (charset-safe ids/domains, base64 run/release,
# secrets travel via stdin).
ci_gate_decision() {
  local app=$1 orig=$2
  [[ -n $orig ]] || { echo "deny interactive access is not permitted"; return; }
  local -a a; read -ra a <<<"$orig"
  local off
  if [[ ${a[0]:-} == sudo && ${a[1]:-} == /usr/local/bin/homeportd ]]; then off=2
  elif [[ ${a[0]:-} == /usr/local/bin/homeportd ]]; then off=1
  else echo "deny may only run homeportd (got '${a[0]:-}')"; return; fi
  local verb=${a[off]:-} arg1=${a[off+1]:-}
  case $verb in
    upload|upload-static|add|activate|rollback|env|env-sync|env-rm|env-list|status|logs)
      [[ $arg1 == "$app" ]] || { echo "deny scoped to '$app', not '${arg1:-(none)}'"; return; } ;;
    version) : ;;
    *) echo "deny verb '${verb:-(none)}' is not permitted"; return ;;
  esac
  echo "allow $off"
}

cmd_ci_gate() {
  local app=${1:-}
  valid_app "$app"
  # the client's request arrives as arg 2 — the forced command passes
  # "$SSH_ORIGINAL_COMMAND" through, because sudo's env_reset drops the env var.
  local orig=${2:-${SSH_ORIGINAL_COMMAND:-}} d
  d=$(ci_gate_decision "$app" "$orig")
  if [[ $d == allow\ * ]]; then
    local off=${d#allow }; local -a a; read -ra a <<<"$orig"
    exec /usr/local/bin/homeportd "${a[@]:off}"
  fi
  die "this key is scoped to '$app' — ${d#deny }"
}

# cmd_activate_static <app> <release> — promote a static release: an atomic
# symlink flip. Caddy's root follows current/ per request, so the new files are
# live the instant the symlink moves — no reload, no process, no downtime.
cmd_activate_static() {
  local app=$1 release=$2
  local dir="$HOMEPORT_ROOT/$app/releases/$release"
  [[ -f "$dir/index.html" ]] || die "no site at $dir (index.html missing) — upload it first"
  # root-owned so the deploy user can't tamper post-activate; a+rX so Caddy
  # (its own user) can read the files and traverse the dirs.
  chown -R root:root "$dir"; chmod -R a+rX "$dir"
  swap_current "$app" "releases/$release"
  prune_releases "$app"
  echo "live: $release (https://$DOMAIN)"
}

cmd_activate() {
  local app=${1:-} release=${2:-}
  valid_app "$app"; valid_release "$release"
  load_app "$app"
  [[ ${STATIC:-} == 1 ]] && { cmd_activate_static "$app" "$release"; return; }
  local dir="$HOMEPORT_ROOT/$app/releases/$release"
  [[ -f "$dir/bin" ]] || die "no binary at $dir/bin — upload it first"
  chown -R root:root "$dir"
  chmod 755 "$dir/bin"

  local prev=""
  [[ -L "$HOMEPORT_ROOT/$app/current" ]] && prev=$(readlink "$HOMEPORT_ROOT/$app/current")

  swap_current "$app" "releases/$release"

  # release hook runs against the new binary while old instances keep serving
  # the previous one — a failed migration aborts the deploy with no disruption.
  if [[ -n ${RELEASE_B64:-} && $RELEASE_B64 != - ]]; then
    local RELEASE
    RELEASE=$(printf %s "$RELEASE_B64" | base64 -d 2>/dev/null) || die "release: invalid encoding"
    echo "release hook: $RELEASE"
    if ! run_deploy_hook "$app" "$RELEASE"; then
      if [[ -n $prev && $prev != "releases/$release" ]]; then
        swap_current "$app" "$prev"
        die "release hook failed — deploy aborted (still on ${prev#releases/})"
      fi
      die "release hook failed — deploy aborted (nothing was activated)"
    fi
  fi

  if activate_and_check "$app"; then
    prune_releases "$app"
    # post_release hook runs after the app is live and healthy — best-effort
    # side effects (cache warm, smoke test, notify). It CANNOT auto-revert (the
    # release is already promoted, a migration may have run), so a failure only
    # warns; put hard gates in release: or the health check instead.
    if [[ -n ${POST_RELEASE_B64:-} && $POST_RELEASE_B64 != - ]]; then
      local POST_RELEASE
      POST_RELEASE=$(printf %s "$POST_RELEASE_B64" | base64 -d 2>/dev/null) || POST_RELEASE=""
      if [[ -n $POST_RELEASE ]]; then
        echo "post-release hook: $POST_RELEASE"
        run_deploy_hook "$app" "$POST_RELEASE" withport \
          || echo "homeportd: warning — post-release hook failed; release is live, investigate and 'homeport rollback' if needed" >&2
      fi
    fi
    local note=""
    [[ -n ${IDLE:-} ]] && note=" · sleeps after ${IDLE_TIMEOUT} idle"
    is_template && note=" · $REPLICAS replicas (rolling)"
    [[ -z ${IDLE:-} ]] && ! is_template && [[ -n ${DOMAIN:-} && -z ${PATH_PREFIX:-} && ${STRATEGY:-blue-green} != recreate ]] && note=" · blue/green"
    if [[ -n ${DOMAIN:-} ]]; then
      echo "live: $release (https://$DOMAIN)$note"
    else
      echo "live: $release (internal, 127.0.0.1:$PORT)$note"
    fi
  else
    if [[ -n $prev && $prev != "releases/$release" ]]; then
      swap_current "$app" "$prev"
      activate_and_check "$app" >/dev/null 2>&1 || true
      die "health check failed — reverted to ${prev#releases/}"
    fi
    systemctl stop "homeport-$app" 2>/dev/null || true
    die "health check failed and there is no previous release to revert to"
  fi
}

cmd_rollback() {
  local app=${1:-} release=${2:-}
  valid_app "$app"; load_app "$app"
  if [[ -z $release ]]; then
    local current r
    current=$(readlink "$HOMEPORT_ROOT/$app/current" 2>/dev/null || true)
    current=${current#releases/}
    local -a releases
    mapfile -t releases < <(ls -1 "$HOMEPORT_ROOT/$app/releases" | sort -r)
    for r in "${releases[@]}"; do
      # strictly older than the live release — never "roll forward" onto a
      # newer upload that was never activated (it may be broken)
      [[ -n $current && ( $r == "$current" || ! $r < $current ) ]] && continue
      release=$r
      break
    done
    [[ -n $release ]] || die "no older release to roll back to"
  fi
  cmd_activate "$app" "$release"
}

cmd_env() { # merge KEY=value lines from stdin into the app's env file
  local app=${1:-}
  valid_app "$app"; load_app "$app"
  local file="$HOMEPORT_ROOT/$app/shared/env" line key
  local -A vars=()
  local -a order=()
  if [[ -f $file ]]; then
    while IFS= read -r line; do
      [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      key=${line%%=*}
      [[ -n ${vars[$key]+x} ]] || order+=("$key")
      vars[$key]=${line#*=}
    done < "$file"
  fi
  local added=0
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "invalid env line (expected KEY=value): '${line%%=*}'"
    key=${line%%=*}
    [[ -n ${vars[$key]+x} ]] || order+=("$key")
    vars[$key]=${line#*=}
    added=$((added + 1))
  done
  (( added > 0 )) || die "no KEY=value lines on stdin"
  local tmp
  tmp=$(mktemp)
  for key in "${order[@]}"; do
    printf '%s=%s\n' "$key" "${vars[$key]}" >> "$tmp"
  done
  install -o root -g "homeport-$app" -m 640 "$tmp" "$file"
  rm -f "$tmp"
  echo "env updated: $added value(s) set, ${#order[@]} total"
  _env_restart "$app"
}

_env_restart() { # restart to pick up new env (mode-aware; idle reloads on wake)
  local app=$1
  if is_template; then
    # health-gated one-at-a-time roll — a blind restart loop could briefly
    # take every instance down on a slow-booting app
    rolling_restart "$app" && echo "rolled $REPLICAS replicas with new env" \
      || die "replica failed health check after env change — check logs"
  elif systemctl is-active --quiet "homeport-$app"; then
    systemctl restart "homeport-$app"
    echo "restarted homeport-$app"
  fi
}

cmd_env_sync() { # DECLARATIVE: replace the env file entirely with stdin
  local app=${1:-}
  valid_app "$app"; load_app "$app"
  local file="$HOMEPORT_ROOT/$app/shared/env" line key
  local -A newvars=(); local -a order=()
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "invalid env line (expected KEY=value): '${line%%=*}'"
    key=${line%%=*}
    [[ -n ${newvars[$key]+x} ]] || order+=("$key")
    newvars[$key]=${line#*=}
  done
  # report keys being dropped (present before, absent now) — never silent
  local -a removed=(); local k
  if [[ -f $file ]]; then
    while IFS= read -r line; do
      [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      k=${line%%=*}; [[ -n ${newvars[$k]+x} ]] || removed+=("$k")
    done < "$file"
  fi
  local tmp; tmp=$(mktemp)
  for key in "${order[@]}"; do printf '%s=%s\n' "$key" "${newvars[$key]}" >> "$tmp"; done
  install -o root -g "homeport-$app" -m 640 "$tmp" "$file"; rm -f "$tmp"
  echo "env synced: ${#order[@]} value(s) (full replace)"
  (( ${#removed[@]} )) && echo "dropped: ${removed[*]}"
  _env_restart "$app"
}

cmd_env_rm() { # remove specific keys (given as args)
  local app=${1:-}; shift || true
  valid_app "$app"; load_app "$app"
  local file="$HOMEPORT_ROOT/$app/shared/env" line k
  [[ -f $file ]] || { echo "(no env set)"; return; }
  (( $# )) || die "no keys given to remove"
  local -A drop=()
  for k in "$@"; do
    [[ $k =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid key: '$k'"
    drop[$k]=1
  done
  local tmp removed=0; tmp=$(mktemp)
  while IFS= read -r line; do
    if [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && [[ -n ${drop[${line%%=*}]+x} ]]; then
      removed=$((removed + 1))
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  install -o root -g "homeport-$app" -m 640 "$tmp" "$file"; rm -f "$tmp"
  echo "removed $removed key(s)"
  (( removed > 0 )) && _env_restart "$app"
}

cmd_env_list() { # keys only — values never leave the box
  local app=${1:-} json=""
  [[ ${2:-} == --json ]] && json=1
  valid_app "$app"; load_app "$app"
  local file="$HOMEPORT_ROOT/$app/shared/env" line key sep=""
  if [[ -n $json ]]; then
    # keys are validated to [A-Za-z_][A-Za-z0-9_]* — safe to emit unescaped
    printf '['
    while IFS= read -r line; do
      [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      key=${line%%=*}
      printf '%s{"key":"%s","chars":%d}' "$sep" "$key" $(( ${#line} - ${#key} - 1 ))
      sep=","
    done < "$file"
    printf ']\n'
    return
  fi
  [[ -s $file ]] || { echo "(no env set)"; return; }
  while IFS= read -r line; do
    [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key=${line%%=*}
    printf '%s (%d chars)\n' "$key" $(( ${#line} - ${#key} - 1 ))
  done < "$file"
}

app_state() { # is-active for an app, whatever its mode (uses $PORT/$REPLICAS)
  local app=$1
  # a static site has no service; it's "active" whenever a release is deployed
  if [[ ${STATIC:-} == 1 ]]; then
    [[ -L "$HOMEPORT_ROOT/$app/current" ]] && echo active || echo inactive
    return
  fi
  if is_template; then
    systemctl is-active "homeport-$app@$(( $(replica_base "$PORT") + 1 ))" 2>/dev/null || true
  else
    systemctl is-active "homeport-$app" 2>/dev/null || true
  fi
}

status_json_one() { # caller must have run load_app for $1
  local app=$1 current state sep="" r
  current=$(readlink "$HOMEPORT_ROOT/$app/current" 2>/dev/null || true)
  current=${current#releases/}
  state=$(app_state "$app")
  # every field is charset-validated on the way in — safe to emit unescaped
  local internal=false idle=false
  [[ -z ${DOMAIN:-} ]] && internal=true
  [[ -n ${IDLE:-} ]] && idle=true
  # app_port = a port that reaches the app directly (tunnel target): idle apps
  # are woken via the public socket; PUBLIC replicas expose no bound public port
  # so point at instance 1; internal load-balanced apps DO bind :PORT (Caddy on
  # loopback) so keep it; plain apps listen on the public port themselves.
  local app_port=$PORT
  is_template && [[ -n ${DOMAIN:-} ]] && app_port=$(( $(replica_base "$PORT") + 1 ))
  # autoscale telemetry: current per-instance cpu% (empty if not autoscaling)
  local as_min=${AUTOSCALE_MIN:-0} as_max=${AUTOSCALE_MAX:-0} as_target=${AUTOSCALE_TARGET:-0} as_cpu=""
  [[ -n ${AUTOSCALE_MAX:-} && -f "$HOMEPORT_ROOT/$app/.autoscale" ]] &&
    as_cpu=$(grep -m1 '^AS_CPU_PCT=' "$HOMEPORT_ROOT/$app/.autoscale" | cut -d= -f2)
  printf '{"app":"%s","domain":"%s","path":"%s","internal":%s,"idle":%s,"replicas":%d,"autoscale_min":%d,"autoscale_max":%d,"autoscale_target":%d,"cpu_pct":"%s","port":%d,"app_port":%d,"state":"%s","release":"%s","releases":[' \
    "$app" "${DOMAIN:-}" "${PATH_PREFIX:-}" "$internal" "$idle" "${REPLICAS:-1}" "$as_min" "$as_max" "$as_target" "${as_cpu}" "$PORT" "$app_port" "$state" "$current"
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    printf '%s"%s"' "$sep" "$r"
    sep=","
  done < <(ls -1 "$HOMEPORT_ROOT/$app/releases" 2>/dev/null | sort -r)
  printf ']}'
}

cmd_status() {
  local app="" json="" a
  for a in "$@"; do
    case $a in
      --json) json=1 ;;
      *) app=$a ;;
    esac
  done
  if [[ -z $app ]]; then
    local c name first=1
    [[ -n $json ]] && printf '['
    for c in "$HOMEPORT_ETC"/*/config; do
      [[ -f $c ]] || continue
      name=$(basename "$(dirname "$c")")
      if [[ -n $json ]]; then
        (( first )) || printf ','
        load_app "$name"
        status_json_one "$name"
      else
        (( first )) || echo
        cmd_status "$name"
      fi
      first=0
    done
    if [[ -n $json ]]; then
      printf ']\n'
    elif (( first )); then
      echo "no apps registered yet"
    fi
    return
  fi
  valid_app "$app"; load_app "$app"
  if [[ -n $json ]]; then
    status_json_one "$app"
    echo
    return
  fi
  local current state
  current=$(readlink "$HOMEPORT_ROOT/$app/current" 2>/dev/null || echo "(none)")
  state=$(app_state "$app")
  echo "app:      $app"
  if [[ -n ${DOMAIN:-} ]]; then
    echo "domain:   https://$DOMAIN${PATH_PREFIX:-}  (127.0.0.1:$PORT)"
  else
    echo "domain:   (internal — 127.0.0.1:$PORT, reach via homeport tunnel)"
  fi
  [[ -n ${IDLE:-} ]] && echo "mode:     scale-to-zero (sleeps after ${IDLE_TIMEOUT} idle)"
  if [[ -n ${AUTOSCALE_MAX:-} ]]; then
    # like `kubectl get hpa`: current cpu% / target, replicas, min-max
    local aspct=""
    [[ -f "$HOMEPORT_ROOT/$app/.autoscale" ]] &&
      aspct=$(grep -m1 '^AS_CPU_PCT=' "$HOMEPORT_ROOT/$app/.autoscale" | cut -d= -f2)
    echo "replicas: $REPLICAS  (autoscale ${AUTOSCALE_MIN}-${AUTOSCALE_MAX})"
    echo "cpu:      ${aspct:-–}% / ${AUTOSCALE_TARGET}% target"
  elif [[ ${REPLICAS:-1} -gt 1 ]]; then
    echo "replicas: $REPLICAS (Caddy load-balanced, rolling deploys)"
  fi
  echo "state:    $state"
  echo "release:  ${current#releases/}"
  echo "releases: $(ls -1 "$HOMEPORT_ROOT/$app/releases" 2>/dev/null | sort -r | tr '\n' ' ')"
}

cmd_key_add() { # [--scope <app>] — append validated SSH public key(s) from stdin.
  # With --scope, each key is prefixed with an SSH forced command so it can ONLY
  # reach ci-gate for that app (deploy that one app, nothing else). Without it,
  # the key gets full homeportd access (an admin credential for the box).
  local scope=""
  if [[ ${1:-} == --scope ]]; then scope=${2:-}; valid_app "$scope"; fi
  local file=/home/deploy/.ssh/authorized_keys line added=0 prefix="" entry
  # `restrict` = no pty / agent / port / X11 forwarding, no user rc — so the key
  # can do exactly one thing: run the forced command. The client's request is
  # passed as a double-quoted argument ("$SSH_ORIGINAL_COMMAND" is expanded by
  # the deploy user's shell that runs the forced command); a double-quoted
  # expansion is one argument and is not re-tokenized, so it can't inject.
  [[ -n $scope ]] && prefix="command=\"sudo /usr/local/bin/homeportd ci-gate $scope \\\"\$SSH_ORIGINAL_COMMAND\\\"\",restrict "
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^(sk-)?(ssh|ecdsa)-[a-z0-9@.-]+\ [A-Za-z0-9+/=]+( .*)?$ ]] \
      || die "line does not look like an SSH public key: '${line:0:40}...'"
    entry="${prefix}${line}"
    if ! grep -qxF "$entry" "$file" 2>/dev/null; then
      echo "$entry" >> "$file"
      added=$((added + 1))
    fi
  done
  chown deploy:deploy "$file"
  chmod 600 "$file"
  echo "added $added key(s)${scope:+ scoped to '$scope'}"
}

cmd_key_list() { # fingerprints + scope of every authorized key
  local file=/home/deploy/.ssh/authorized_keys line fp scope
  [[ -s $file ]] || { echo "(no keys)"; return; }
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    fp=$(printf '%s\n' "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null) || continue
    if [[ $line == command=\"sudo\ /usr/local/bin/homeportd\ ci-gate\ * ]]; then
      # scope ends at the first space, quote, or comma — covers both the
      # current format (ci-gate app \"$SSH_ORIGINAL_COMMAND\"") and older
      # argless lines (ci-gate app",restrict)
      scope=${line#*ci-gate }; scope=${scope%%[ '",']*}
      echo "$fp [scoped: $scope]"
    else
      echo "$fp [full access]"
    fi
  done < "$file"
}

cmd_key_rm() { # <SHA256:fingerprint | key comment> — revoke authorized key(s)
  local sel=${1:-}
  [[ -n $sel ]] || die "usage: key-rm <SHA256:fingerprint | key comment>  (see key-list)"
  local file=/home/deploy/.ssh/authorized_keys line fp tmp removed=0 kept=0
  [[ -s $file ]] || die "no authorized keys"
  tmp=$(mktemp)
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && { printf '%s\n' "$line" >> "$tmp"; continue; }
    fp=$(printf '%s\n' "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}')
    # match the full fingerprint, or the key's trailing comment (e.g. the
    # homeport-ci-<app> comment ci setup stamps on CI keys)
    if [[ ( -n $fp && $fp == "$sel" ) || $line == *" $sel" ]]; then
      removed=$((removed + 1))
    else
      printf '%s\n' "$line" >> "$tmp"; kept=$((kept + 1))
    fi
  done < "$file"
  (( removed > 0 )) || { rm -f "$tmp"; die "no key matched '$sel' — see key-list"; }
  (( kept > 0 )) || { rm -f "$tmp"; die "refusing — that would remove the LAST key and lock you out"; }
  install -o deploy -g deploy -m 600 "$tmp" "$file"; rm -f "$tmp"
  echo "revoked $removed key(s); $kept remain"
}

cmd_version() {
  if [[ ${1:-} == --json ]]; then
    printf '{"homeportd":"%s","api":%d}\n' "$HOMEPORTD_VERSION" "$HOMEPORTD_API"
  else
    echo "homeportd $HOMEPORTD_VERSION (api $HOMEPORTD_API)"
  fi
}

cmd_self_update() { # replace this script with a validated copy from stdin
  # Trust model, stated plainly: anyone who can run this (the deploy user,
  # via sudo) can make homeportd do anything — so the deploy key is an
  # admin credential for this box. Scoped per-app CI keys are the future
  # mitigation; until then, treat deploy keys like root keys.
  local tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if ! head -5 "$tmp" | grep -q '^# homeportd '; then
    rm -f "$tmp"
    die "stdin does not look like a homeportd script"
  fi
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "new script failed the syntax check — not installed"
  fi
  local newver
  newver=$(grep -m1 '^HOMEPORTD_VERSION=' "$tmp" | cut -d= -f2)
  [[ -n $newver ]] || { rm -f "$tmp"; die "new script declares no HOMEPORTD_VERSION"; }
  install -o root -g root -m 755 "$tmp" /usr/local/bin/homeportd
  rm -f "$tmp"
  echo "homeportd updated: $HOMEPORTD_VERSION -> $newver"
}

cmd_logs() {
  local app=${1:-}
  valid_app "$app"
  shift || true
  # exact units only — a bare "homeport-$app*" glob would also match a
  # sibling app whose name shares the prefix (web vs webshop)
  local -a args=(-u "homeport-$app.service" -u "homeport-$app@*" -u "homeport-$app-proxy.service" --no-pager -n 100)
  while (( $# )); do
    case $1 in
      -f) args+=(-f) ;;
      -n) [[ ${2:-} =~ ^[0-9]+$ ]] || die "-n needs a number"; args+=(-n "$2"); shift ;;
      *)  die "unknown logs option: $1" ;;
    esac
    shift
  done
  journalctl "${args[@]}"
}

cmd_remove() {
  local app=${1:-}
  valid_app "$app"
  [[ ${2:-} == --yes ]] || die "this deletes the app, its releases and env — re-run as: remove $app --yes"
  # capture replica + gateway info before the config is deleted
  local replicas=1 port=0
  local as_max=0 gwdom="" gwpath=""
  [[ -f "$HOMEPORT_ETC/$app/config" ]] && { load_app "$app"; replicas=${REPLICAS:-1}; port=$PORT; as_max=${AUTOSCALE_MAX:-0}; gwdom=${DOMAIN:-}; gwpath=${PATH_PREFIX:-}; }
  systemctl disable --now "homeport-$app" 2>/dev/null || true
  # scale-to-zero units, if this was an idle app
  systemctl disable --now "homeport-$app-proxy.socket" 2>/dev/null || true
  systemctl stop "homeport-$app-proxy.service" 2>/dev/null || true
  _teardown_autoscale_timer "$app"
  # replica/autoscale instances — tear down every slot the app could have used
  # (autoscale may sit at 1 but still be a template instance; max bounds it)
  local top=$replicas
  (( as_max > top )) && top=$as_max
  if [[ $top -gt 1 || $as_max -gt 0 ]]; then
    local rbase i
    rbase=$(replica_base "$port")
    for (( i = 1; i <= top; i++ )); do
      systemctl disable --now "homeport-$app@$((rbase + i))" 2>/dev/null || true
    done
  fi
  systemctl stop "homeport-$app-green.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/homeport-$app.service" \
        "/etc/systemd/system/homeport-$app@.service" \
        "/etc/systemd/system/homeport-$app-green.service" \
        "/etc/systemd/system/homeport-$app-proxy.socket" \
        "/etc/systemd/system/homeport-$app-proxy.service" \
        "$CADDY_DIR/$app.caddy"
  systemctl daemon-reload
  systemctl reload caddy 2>/dev/null || true
  rm -rf "${HOMEPORT_ROOT:?}/${app:?}" "${HOMEPORT_ETC:?}/${app:?}"
  # if this was a path-mounted app, rebuild its host's gateway without it (the
  # config is gone now, so the scan naturally excludes it).
  if [[ -n $gwpath && -n $gwdom ]]; then
    write_gateway "$gwdom"
    systemctl reload caddy 2>/dev/null || true
  fi
  if id -u "homeport-$app" &>/dev/null; then userdel "homeport-$app"; fi
  echo "removed app '$app'"
}

usage() {
  cat <<'EOF'
homeportd — root-side homeport helper (run via sudo)

  add <app> <domain|-> [health] [mem] [cpu] [idle] [timeout] [replicas]  register an app
  activate <app> <release>           flip symlink, restart, health-check, auto-revert
  rollback <app> [release]           activate the previous (or a given) release
  env <app>                          merge KEY=value lines from stdin into the app env
  env-sync <app>                     replace the app env entirely with stdin (declarative)
  env-rm <app> <key>...              remove keys from the app env
  env-list <app> [--json]            list env keys (values never printed)
  status [app] [--json]              show one app, or all
  logs <app> [-f] [-n N]             app journal
  upload <app> <release>             receive the app binary on stdin into a release dir
  key-add [--scope <app>]            authorize key(s) from stdin; --scope locks them to one app
  key-list                           fingerprints + scope of authorized deploy keys
  key-rm <fingerprint|comment>       revoke a key (e.g. a leaked or retired CI key)
  self-update                        replace homeportd with a validated script from stdin
  version [--json]                   homeportd version and API level
  remove <app> --yes                 delete app, releases, env, user
EOF
}

main() {
  [[ $(id -u) -eq 0 ]] || die "must run as root (the homeport CLI calls this via sudo)"
  local cmd=${1:-}
  shift || true
  case $cmd in
    add)      cmd_add "$@" ;;
    upload)   cmd_upload "$@" ;;
    upload-static) cmd_upload_static "$@" ;;
    ci-gate)  cmd_ci_gate "$@" ;;
    activate) cmd_activate "$@" ;;
    autoscale) cmd_autoscale "$@" ;;
    rollback) cmd_rollback "$@" ;;
    env)      cmd_env "$@" ;;
    env-sync) cmd_env_sync "$@" ;;
    env-rm)   cmd_env_rm "$@" ;;
    env-list) cmd_env_list "$@" ;;
    status)   cmd_status "$@" ;;
    logs)     cmd_logs "$@" ;;
    key-add)  cmd_key_add "$@" ;;
    key-list) cmd_key_list "$@" ;;
    key-rm)   cmd_key_rm "$@" ;;
    self-update) cmd_self_update "$@" ;;
    version)  cmd_version "$@" ;;
    remove)   cmd_remove "$@" ;;
    ""|help|-h|--help) usage ;;
    *) die "unknown command: $cmd (try: homeportd help)" ;;
  esac
}
# run main only when executed, not when sourced (so tests can source the pure
# helpers). BASH_SOURCE[0]==$0 exactly when this file is the running program.
# An `if` (not `&&`) so a sourced load ends on exit 0, not a stray non-zero.
if [[ ${BASH_SOURCE[0]:-} == "${0}" ]]; then main "$@"; fi
HOMEPORTD_SCRIPT
  chmod 755 /usr/local/bin/homeportd
}

main() {
  [[ $(id -u) -eq 0 ]] || die "run as root (ssh root@your-server, or use as Hetzner user data)"
  command -v apt-get >/dev/null || die "this script supports Ubuntu/Debian only"

  export DEBIAN_FRONTEND=noninteractive
  log "Installing base packages"
  apt-get update -qq
  apt-get install -y -qq ufw fail2ban unattended-upgrades curl ca-certificates gnupg >/dev/null

  setup_deploy_user
  setup_firewall
  setup_ssh_hardening
  setup_fail2ban
  setup_auto_upgrades
  setup_sysctl
  setup_caddy
  install_homeportd
  setup_dirs_and_sudo

  local ip
  ip=$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  echo
  log "Done — this box is ready for homeport deploys."
  echo
  echo "  IMPORTANT: root SSH login is now disabled. Connect as:  ssh deploy@$ip"
  echo
  echo "  Next, on your laptop, inside your project:"
  echo "    homeport init                # answers: server = deploy@$ip, your domain"
  echo "    homeport secrets push .env   # upload your env/secrets"
  echo "    homeport deploy              # build, upload, go live"
}

main "$@"
