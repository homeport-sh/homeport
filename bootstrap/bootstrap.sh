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

HOMEPORTD_VERSION=0.9.0
HOMEPORTD_API=1

HOMEPORT_ROOT=/opt/homeport
HOMEPORT_ETC=/etc/homeport/apps
CADDY_DIR=/etc/caddy/homeport.d
CADDYFILE=/etc/caddy/Caddyfile
TLS_CERT_DIR=/etc/caddy/homeport.d/certs   # bring-your-own certs live here, per app
CADDY_ENV_FILE=/etc/caddy/homeport.env     # env vars for Caddy (DNS tokens), root-owned 600
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
    if curl -fs -o /dev/null --max-time 2 "http://$(app_addr "$port"):$port$HEALTH_PATH" 2>/dev/null; then
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
  if sandbox_on; then
    # The app runs inside gVisor; this unit runs homeportd as root to build
    # the sandbox and exec runsc. Limits on the unit bound the whole sandbox.
    cat <<EOF
[Service]
Slice=homeport-tenants.slice
ExecStart=/usr/local/bin/homeportd sandbox-run $app $1
ExecStop=/usr/local/bin/homeportd sandbox-stop $app $1
ExecStopPost=/usr/local/bin/homeportd sandbox-clean $app $1
EnvironmentFile=-$HOMEPORT_ROOT/$app/shared/env
Environment=NODE_ENV=production
Environment=PORT=$1
Environment=NBC_RUNTIME_DIR=$HOMEPORT_ROOT/$app/shared/runtime
Environment=STATE_DIR=$HOMEPORT_ROOT/$app/shared
Restart=on-failure
RestartSec=2
KillMode=mixed
TimeoutStopSec=20
SuccessExitStatus=143 SIGTERM
LimitNOFILE=65536
TasksMax=512
$limits
EOF
    # a memory limit means RAM+swap: on a host with swap, MemoryMax alone lets
    # a tenant page past its limit instead of being stopped at it
    [[ $limits == *MemoryMax=* ]] && echo "MemorySwapMax=0"
    return 0
  fi
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
# No cloud metadata service (169.254.169.254 hands out the droplet's user-data
# and metadata to anyone on the box). Applies even to sandbox: relaxed.
IPAddressDeny=169.254.0.0/16
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

# --- sandbox: gvisor ------------------------------------------------------------
# `sandbox: gvisor` runs an app inside gVisor (runsc): its own kernel (the app
# never makes a syscall to ours), its own network namespace, a read-only root,
# and the app's uid. This is what makes a box safe to share between customers.
# systemd still supervises it — restarts, cgroup limits, journald — through a
# unit whose ExecStart is `homeportd sandbox-run`, which builds the sandbox and
# execs runsc. Proven in design/shared-hosts-gvisor-spike.md (homeport-sh/cloud).
SANDBOX_STATE=/run/homeport-sandbox      # per-instance bundles (rebuilt each start)
SANDBOX_RUNSC_ROOT=/run/homeport-runsc   # runsc's own state
SANDBOX_DNS="1.1.1.1 9.9.9.9"
# read-only host paths a dynamically linked binary (glibc, Bun, Node) and TLS
# clients need; mounted only when present on the host
SANDBOX_RO_PATHS="/lib /lib64 /usr/lib /usr/lib64 /etc/ssl/certs /usr/share/ca-certificates /usr/share/zoneinfo"

sandbox_on() { [[ ${SANDBOX:-} == gvisor ]]; }

# validate_sandbox <sandbox> <release_b64> <post_release_b64>
validate_sandbox() {
  local sb=${1:-} rel=${2:-} post=${3:-}
  [[ $rel == - ]] && rel=""; [[ $post == - ]] && post=""
  case $sb in
    ""|strict|relaxed) return 0 ;;
    gvisor)
      # hooks run natively as the app user — customer code outside the sandbox
      [[ -z $rel && -z $post ]] || die "sandbox: gvisor apps can't have release/post_release hooks yet (they would run outside the sandbox)"
      return 0 ;;
  esac
  die "sandbox must be 'strict' (default), 'relaxed', or 'gvisor'"
}

# validate_egress <sandbox> <egress> — a sandbox's outbound policy:
#   full (default)  anything but mail and our own networks
#   web             web, DNS and database ports only (the free tier)
validate_egress() {
  local sb=${1:-} eg=${2:-}
  [[ $eg == - ]] && eg=""
  [[ -z $eg ]] && return 0
  [[ $sb == gvisor ]] || die "egress is a sandbox: gvisor setting"
  [[ $eg == web || $eg == full ]] || die "egress must be 'full' (default) or 'web'"
}

# sandbox_veth <port> <egress> — the host side of an instance's link. The
# policy is in the NAME: the firewall matches hpvw* for web-only, hpv* for
# every sandbox. No per-sandbox firewall state, so re-applying the rules on
# any start can never lose another sandbox's policy.
sandbox_veth() { if [[ ${2:-} == web ]]; then echo "hpvw$1"; else echo "hpv$1"; fi; }

# sandbox_ip <port> <host|guest> — the instance's /30 inside 100.64.0.0/14,
# keyed by the port it serves: unique on the box, valid for any port.
sandbox_ip() {
  local n=$(( $1 * 4 ))
  local a=$(( 64 + (n >> 16) )) b=$(( (n >> 8) & 255 )) c=$(( n & 255 ))
  if [[ ${2:-guest} == host ]]; then echo "100.$a.$b.$((c + 1))"; else echo "100.$a.$b.$((c + 2))"; fi
}

# sandbox_id <app> <port> — a runsc container id. runsc matches ids by PREFIX,
# so ids end in "_" and app names can't contain one: no id is ever a prefix
# of another.
sandbox_id() { echo "hp_${1}_${2}_"; }

# app_addr <port> — where the loaded app's instance on <port> is reached.
app_addr() { if sandbox_on; then sandbox_ip "$1" guest; else echo 127.0.0.1; fi; }

# sandbox_spec --uid --gid --cwd --bin --args --release --shared --netns
#              --hostname --env-file — print the OCI config. --env-file holds
# NUL-separated KEY=value pairs (the unit's environment, as systemd parsed it),
# so values reach the app byte-for-byte, quotes and newlines included.
sandbox_spec() {
  local uid gid cwd bin args="" release shared netns host envf
  while [[ $# -gt 0 ]]; do
    case $1 in
      --uid) uid=$2 ;; --gid) gid=$2 ;; --cwd) cwd=$2 ;; --bin) bin=$2 ;;
      --args) args=$2 ;; --release) release=$2 ;; --shared) shared=$2 ;;
      --netns) netns=$2 ;; --hostname) host=$2 ;; --env-file) envf=$2 ;;
      *) die "sandbox_spec: unknown flag $1" ;;
    esac
    shift 2
  done
  local ro="" p
  for p in $SANDBOX_RO_PATHS; do [[ -e $p ]] && ro+="$p "; done
  # run args were validated to a quote-free charset: whitespace split is exact
  local -a argv=("$bin"); local a argj
  for a in $args; do argv+=("$a"); done
  # argv as JSON from NUL-separated input: jq would parse a positional
  # "--port" as one of its own options.
  argj=$(printf '%s\0' "${argv[@]}" | jq -Rs 'split("\u0000")[:-1]')
  jq -n \
    --argjson argv "$argj" \
    --argjson uid "$uid" --argjson gid "$gid" --arg cwd "$cwd" \
    --arg release "$release" --arg shared "$shared" --arg netns "$netns" --arg host "$host" \
    --arg ro "$ro" \
    --rawfile envraw "$envf" \
    '{
      ociVersion: "1.0.2",
      process: {
        terminal: false,
        user: {uid: $uid, gid: $gid},
        args: $argv,
        env: (
          ($envraw | split("\u0000") | map(select(length > 0))
            | map(select(test("^(INVOCATION_ID|JOURNAL_STREAM|SYSTEMD_EXEC_PID|NOTIFY_SOCKET|MAINPID|MANAGERPID|LISTEN_[A-Z]+|WATCHDOG_[A-Z]+|PATH|HOST|HOSTNAME|HOME|LOGNAME|USER|SHELL|LANG|TERM)=") | not)))
          + ["PATH=/usr/local/bin:/usr/bin:/bin", "HOST=0.0.0.0", "HOSTNAME=0.0.0.0"]
        ),
        cwd: $cwd,
        noNewPrivileges: true,
        capabilities: {bounding: [], effective: [], inheritable: [], permitted: [], ambient: []},
        rlimits: [{type: "RLIMIT_NOFILE", hard: 65536, soft: 65536}]
      },
      root: {path: "rootfs", readonly: true},
      hostname: $host,
      mounts: (
        [ {destination: "/proc", type: "proc", source: "proc"},
          {destination: "/tmp", type: "tmpfs", source: "tmpfs", options: ["nosuid", "nodev", "size=64m"]},
          {destination: $cwd, type: "bind", source: $release, options: ["rbind", "ro"]},
          {destination: $shared, type: "bind", source: $shared, options: ["rbind", "rw"]} ]
        + ($ro | split(" ") | map(select(length > 0)) | map({destination: ., type: "bind", source: ., options: ["rbind", "ro"]}))
      ),
      linux: {
        namespaces: [{type: "pid"}, {type: "ipc"}, {type: "uts"}, {type: "mount"}, {type: "network", path: $netns}]
      }
    }'
}

# sandbox_firewall_rules — the host firewall for every sandbox, as one nft
# script (applied atomically). Sandboxes reach the internet and nothing of
# ours: not the host, not each other, not the cloud metadata service, not a
# private network (the CA, the database), no mail server (a blacklisted IP
# hurts every tenant on the host). A web-only sandbox (hpvw*, the free tier)
# reaches web, DNS and database ports and nothing else. Order matters in
# forward: the denies come before the accept.
sandbox_firewall_rules() {
  cat <<'NFT'
table inet homeport_sandbox
delete table inet homeport_sandbox
table inet homeport_sandbox {
	chain input {
		type filter hook input priority -10; policy accept;
		iifname "hpv*" ct state established,related accept
		iifname "hpv*" drop
	}
	chain forward {
		type filter hook forward priority -10; policy accept;
		iifname "hpv*" oifname "hpv*" drop
		iifname "hpv*" ip daddr { 169.254.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 127.0.0.0/8, 0.0.0.0/8, 224.0.0.0/4, 240.0.0.0/4 } drop
		iifname "hpv*" tcp dport { 25, 465, 587 } drop
		iifname "hpvw*" tcp dport != { 53, 80, 443, 3306, 5432, 6379, 27017 } drop
		iifname "hpvw*" udp dport != 53 drop
		iifname "hpvw*" meta l4proto != { tcp, udp } drop
		iifname "hpv*" accept
		oifname "hpv*" ct state established,related accept
		oifname "hpv*" drop
	}
}
table ip homeport_sandbox_nat
delete table ip homeport_sandbox_nat
table ip homeport_sandbox_nat {
	chain postrouting {
		type nat hook postrouting priority 100; policy accept;
		ip saddr 100.64.0.0/14 oifname != "hpv*" masquerade
	}
}
NFT
}

# ensure_sandbox_firewall — idempotent; run on every sandbox start (the nft
# tables don't survive a reboot; the units that need them recreate them).
ensure_sandbox_firewall() {
  sysctl -qw net.ipv4.ip_forward=1
  echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/98-homeport-sandbox.conf
  # ufw drops forwarded traffic by default, which would also drop sandbox
  # egress; homeport_sandbox's forward chain is the forward policy instead.
  if [[ -f /etc/default/ufw ]] && ! grep -q '^DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw; then
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    ufw reload >/dev/null 2>&1 || true
  fi
  sandbox_firewall_rules | nft -f - || die "sandbox: could not apply the sandbox firewall"
}

sandbox_net_up() { # <port> [egress]
  local port=$1 ns="hp-$1" vs="hps$1"
  local vh; vh=$(sandbox_veth "$port" "${2:-}")
  local host guest; host=$(sandbox_ip "$port" host); guest=$(sandbox_ip "$port" guest)
  ip netns add "$ns"
  ip link add "$vh" type veth peer name "$vs" netns "$ns"
  ip addr add "$host/30" dev "$vh"; ip link set "$vh" up
  ip -n "$ns" addr add "$guest/30" dev "$vs"; ip -n "$ns" link set "$vs" up
  ip -n "$ns" link set lo up
  # gVisor snapshots routes when the sandbox starts: add before runsc runs
  ip -n "$ns" route add default via "$host"
}

sandbox_net_down() { # <port>
  ip link del "hpv$1" 2>/dev/null || true
  ip link del "hpvw$1" 2>/dev/null || true
  ip netns del "hp-$1" 2>/dev/null || true
}

sandbox_check_tools() {
  local t
  for t in runsc jq nft ip; do
    command -v "$t" >/dev/null || die "sandbox: '$t' is not installed — run: homeport server sandbox install"
  done
}

# --- the tenant slice ----------------------------------------------------------
# Every sandbox runs in homeport-tenants.slice, capped below the host's RAM.
# Each app has its own limit, but apps that can sleep are packed on the
# expectation that most are asleep; if many wake at once, the slice is what
# keeps them — together — from starving the host's own services (Caddy, sshd,
# homeportd). At the cap the kernel reclaims, then OOM-kills inside the slice;
# systemd restarts that app. The host itself never runs out.

# tenant_slice_max_bytes <MemTotal kB> — the host's RAM less a reserve of 10%
# (at least 1 GiB), but never less than half.
tenant_slice_max_bytes() {
  local total=$(( $1 * 1024 )) reserve
  reserve=$(( total / 10 ))
  (( reserve < 1073741824 )) && reserve=1073741824
  local max=$(( total - reserve ))
  (( max < total / 2 )) && max=$(( total / 2 ))
  echo "$max"
}

tenant_slice_unit() { # <max bytes>
  cat <<EOF
[Unit]
Description=homeport tenant sandboxes

[Slice]
MemoryMax=$1
MemoryHigh=$(( $1 / 10 * 9 ))
MemorySwapMax=0
EOF
}

# ensure_tenant_slice — (re)write the slice for this host's RAM; idempotent.
ensure_tenant_slice() {
  local f=/etc/systemd/system/homeport-tenants.slice want
  want=$(tenant_slice_unit "$(tenant_slice_max_bytes "$(awk '/^MemTotal:/{print $2}' /proc/meminfo)")")
  [[ -f $f && $(cat "$f") == "$want" ]] && return 0
  printf '%s\n' "$want" > "$f"
  systemctl daemon-reload
}

# cmd_sandbox_run <app> <port> — ExecStart of a gvisor app's unit (as root).
cmd_sandbox_run() {
  local app=${1:-} port=${2:-}
  valid_app "$app"; [[ $port =~ ^[0-9]{2,5}$ ]] || die "sandbox-run: invalid port '$port'"
  load_app "$app"
  sandbox_on || die "sandbox-run: app '$app' is not sandbox: gvisor"
  sandbox_check_tools
  local id b user="homeport-$app" release uid gid
  id=$(sandbox_id "$app" "$port"); b="$SANDBOX_STATE/$id"
  # a crash can leave the last run behind
  cmd_sandbox_clean "$app" "$port" >/dev/null 2>&1 || true
  ensure_sandbox_firewall
  release=$(readlink -f "$HOMEPORT_ROOT/$app/current") || die "sandbox-run: '$app' has no current release"
  [[ -x $release/bin ]] || die "sandbox-run: no binary at $release/bin"
  uid=$(id -u "$user") gid=$(id -g "$user")
  install -d -m 700 "$b" "$SANDBOX_RUNSC_ROOT"
  install -d -m 755 "$b/rootfs" "$b/rootfs/etc" "$b/rootfs/tmp" "$b/rootfs/proc"
  # minimal /etc: who the app is, how it resolves names
  printf 'root:x:0:0:root:/:/usr/sbin/nologin\n%s:x:%s:%s::%s:/usr/sbin/nologin\n' "$user" "$uid" "$gid" "$HOMEPORT_ROOT/$app" > "$b/rootfs/etc/passwd"
  printf 'root:x:0:\n%s:x:%s:\n' "$user" "$gid" > "$b/rootfs/etc/group"
  printf '127.0.0.1 localhost %s\n' "$app" > "$b/rootfs/etc/hosts"
  local d; : > "$b/rootfs/etc/resolv.conf"
  for d in $SANDBOX_DNS; do echo "nameserver $d" >> "$b/rootfs/etc/resolv.conf"; done
  echo 'hosts: files dns' > "$b/rootfs/etc/nsswitch.conf"
  # the app's environment exactly as systemd parsed it for this unit
  env -0 > "$b/env"; chmod 600 "$b/env"
  local args=""
  if [[ -n ${RUN_B64:-} && $RUN_B64 != - ]]; then
    args=$(printf %s "$RUN_B64" | base64 -d)
    args=${args//\$\{PORT\}/$port}; args=${args//\$PORT/$port}
    args=${args//\$\{HOST\}/0.0.0.0}; args=${args//\$HOST/0.0.0.0}
  fi
  sandbox_spec --uid "$uid" --gid "$gid" --cwd "$HOMEPORT_ROOT/$app/current" --bin "$HOMEPORT_ROOT/$app/current/bin" \
    --args "$args" --release "$release" --shared "$HOMEPORT_ROOT/$app/shared" \
    --netns "/var/run/netns/hp-$port" --hostname "$app" --env-file "$b/env" > "$b/config.json"
  rm -f "$b/env"; chmod 600 "$b/config.json"   # holds the app's secrets
  sandbox_net_up "$port" "${EGRESS:-}"
  # --ignore-cgroups: the sandbox stays in this unit's cgroup, so systemd's
  # MemoryMax/CPUQuota/TasksMax bound the WHOLE sandbox (sentry included).
  exec runsc --root="$SANDBOX_RUNSC_ROOT" --ignore-cgroups --network=sandbox \
    run --bundle "$b" "$id"
}

# cmd_sandbox_stop <app> <port> — ExecStop: ask the app to exit cleanly.
cmd_sandbox_stop() {
  local app=${1:-} port=${2:-} id i
  valid_app "$app"; [[ $port =~ ^[0-9]{2,5}$ ]] || die "sandbox-stop: invalid port"
  id=$(sandbox_id "$app" "$port")
  runsc --root="$SANDBOX_RUNSC_ROOT" kill "$id" TERM 2>/dev/null || return 0
  for i in $(seq 1 40); do
    runsc --root="$SANDBOX_RUNSC_ROOT" state "$id" 2>/dev/null | grep -q '"status": "running"' || return 0
    sleep 0.25
  done
}

# cmd_sandbox_clean <app> <port> — ExecStopPost: leave nothing behind.
cmd_sandbox_clean() {
  local app=${1:-} port=${2:-} id
  valid_app "$app"; [[ $port =~ ^[0-9]{2,5}$ ]] || die "sandbox-clean: invalid port"
  id=$(sandbox_id "$app" "$port")
  if command -v runsc >/dev/null; then
    runsc --root="$SANDBOX_RUNSC_ROOT" kill "$id" KILL 2>/dev/null || true
    runsc --root="$SANDBOX_RUNSC_ROOT" delete -force "$id" 2>/dev/null || true
  fi
  sandbox_net_down "$port"
  rm -rf "${SANDBOX_STATE:?}/${id:?}"
}

# cmd_sandbox_install — gVisor from its signed apt repository, plus the tools
# sandbox-run needs.
cmd_sandbox_install() {
  command -v apt-get >/dev/null || die "sandbox install supports Ubuntu/Debian only"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg jq nftables iproute2 >/dev/null
  curl -fsSL https://gvisor.dev/archive.key | gpg --dearmor --yes -o /usr/share/keyrings/gvisor-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" \
    > /etc/apt/sources.list.d/gvisor.list
  apt-get update -qq
  apt-get install -y -qq runsc >/dev/null
  ensure_meter_timer
  ensure_tenant_slice
  echo "sandbox: $(runsc --version | head -1) installed (usage metering on)"
}

# --- usage metering --------------------------------------------------------------
# Every 60s `meter-tick` (a systemd timer) records, per app: time awake, its
# size, CPU used and bytes sent, into a numbered local spool. The control plane
# pulls it with `meter-read`, and only once it has stored the records does it
# `meter-ack`, which deletes them. A retry re-sends the same sequence numbers,
# so nothing is lost while the control plane is down and nothing is billed
# twice. Records carry DELTAS since the previous tick: counters reset when an
# app restarts, and that must not look like a spike or go negative.
METER_DIR=/var/lib/homeport/meter
METER_READ_MAX=5000

# meter_awake_us <last> <now> <state> <active-enter> <inactive-enter> — µs the
# unit was awake in (last, now], from systemd's monotonic timestamps.
meter_awake_us() {
  local last=$1 now=$2 state=$3 ae=${4:-0} ie=${5:-0} start awake=0
  case $state in
    active|activating|reloading|deactivating|refreshing)
      start=$(( ae > last ? ae : last )); awake=$(( now - start )) ;;
    *)
      if (( ie > last && ae > 0 && ae < ie )); then
        start=$(( ae > last ? ae : last )); awake=$(( ie - start ))
      fi ;;
  esac
  (( awake < 0 )) && awake=0
  (( awake > now - last )) && awake=$(( now - last ))
  echo "$awake"
}

# meter_delta <prev> <cur> <same|new> — growth of a counter since the last tick.
# A new identity (restart, recreated link) or a counter that went backwards
# starts over at cur; no previous reading sets a baseline and bills nothing.
meter_delta() {
  local prev=$1 cur=${2:-0} ident=$3
  [[ -z $prev ]] && { echo 0; return; }
  if [[ $ident != same ]] || (( cur < prev )); then echo "$cur"; else echo $(( cur - prev )); fi
}

# meter_instances <app> — "<unit> <port>" per instance of the LOADED app.
meter_instances() {
  local app=$1 n i p rbase
  if [[ ${REPLICAS:-1} -gt 1 || -n ${AUTOSCALE_MAX:-} ]]; then
    n=${REPLICAS:-1}; [[ -n ${AUTOSCALE_MAX:-} && $AUTOSCALE_MAX -gt $n ]] && n=$AUTOSCALE_MAX
    rbase=$(replica_base "$PORT")
    for (( i = 1; i <= n; i++ )); do p=$((rbase + i)); echo "homeport-$app@$p $p"; done
  else
    p=$PORT; [[ -n ${IDLE:-} ]] && p=$((PORT + 1000))
    echo "homeport-$app $p"
  fi
}

meter_mb() { # <512M|1G|…> → MB (0 when unset)
  local m=${1:-}
  case $m in
    *G) echo $(( ${m%G} * 1024 )) ;;
    *M) echo "${m%M}" ;;
    *K) echo $(( ${m%K} / 1024 )) ;;
    *) echo 0 ;;
  esac
}

# meter_record <seq> <start> <end> <app> <memory_mb> <awake_ms> <cpu_ms> <egress_bytes>
# (every field is a number or a validated app name: no escaping needed)
meter_record() {
  printf '{"seq":%s,"start":%d,"end":%d,"app":"%s","memory_mb":%d,"awake_ms":%d,"mb_ms":%d,"cpu_ms":%d,"egress_bytes":%d}' \
    "$1" "$2" "$3" "$4" "$5" "$6" $(( $5 * $6 )) "$7" "$8"
}

_meter_lock() { # hold METER_DIR/lock for the rest of the calling (sub)shell
  mkdir -p "$METER_DIR"
  command -v flock >/dev/null || return 0
  exec 9>"$METER_DIR/lock"; flock 9
}

# meter_append <record with __SEQ__> — number it and add it to the spool
meter_append() {
  local seq
  seq=$(( $(cat "$METER_DIR/seq" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "${1/__SEQ__/$seq}" >> "$METER_DIR/spool"
  echo "$seq" > "$METER_DIR/seq.tmp" && mv "$METER_DIR/seq.tmp" "$METER_DIR/seq"
}

meter_read() { # <after-seq> — spooled records with seq > after, oldest first
  [[ -f $METER_DIR/spool ]] || return 0
  awk -v after="$1" -v max="$METER_READ_MAX" '
    match($0, /"seq":[0-9]+/) { s = substr($0, RSTART + 6, RLENGTH - 6) + 0
      if (s > after && n < max) { print; n++ } }' "$METER_DIR/spool"
}

meter_ack() { # <seq> — drop records up to seq (the control plane has them)
  [[ -f $METER_DIR/spool ]] || return 0
  awk -v ack="$1" 'match($0, /"seq":[0-9]+/) { if (substr($0, RSTART + 6, RLENGTH - 6) + 0 > ack) print }' \
    "$METER_DIR/spool" > "$METER_DIR/spool.tmp" && mv "$METER_DIR/spool.tmp" "$METER_DIR/spool"
}

# cmd_meter_tick — one minute of usage for every app on the box.
cmd_meter_tick() {
  _meter_lock
  local now_us now_unix last_us="" last_unix="" line
  now_us=$(awk '{ printf "%d", $1 * 1000000 }' /proc/uptime)
  now_unix=$(date +%s)
  local -A prev=()
  if [[ -f $METER_DIR/state ]]; then
    read -r last_us last_unix < "$METER_DIR/state"
    while read -r key val; do [[ -n $key ]] && prev[$key]=$val; done < <(tail -n +2 "$METER_DIR/state")
  fi
  # after a reboot the monotonic clock restarts: start over from a baseline
  [[ -n $last_us && $last_us -gt $now_us ]] && last_us=""
  local next="$now_us $now_unix"$'\n'
  local cfg app inst unit port
  for cfg in "$HOMEPORT_ETC"/*/config; do
    [[ -f $cfg ]] || continue
    app=$(basename "$(dirname "$cfg")")
    local mem awake=0 cpu=0 egress=0 insts
    insts=$( load_app "$app"; [[ ${STATIC:-} == 1 ]] && exit 0; meter_instances "$app" )
    mem=$( load_app "$app"; meter_mb "${MEMORY:-}" )
    while read -r unit port; do
      [[ -n $unit ]] || continue
      local st="" ae=0 ie=0 cpu_ns=0 inv="" k v
      while IFS='=' read -r k v; do
        case $k in
          ActiveState) st=$v ;;
          ActiveEnterTimestampMonotonic) ae=${v:-0} ;;
          InactiveEnterTimestampMonotonic) ie=${v:-0} ;;
          CPUUsageNSec) [[ $v =~ ^[0-9]+$ ]] && cpu_ns=$v ;;
          InvocationID) inv=$v ;;
        esac
      done < <(systemctl show "$unit" -p ActiveState,ActiveEnterTimestampMonotonic,InactiveEnterTimestampMonotonic,CPUUsageNSec,InvocationID 2>/dev/null)
      if [[ -n $last_us ]]; then
        awake=$(( awake + $(meter_awake_us "$last_us" "$now_us" "$st" "$ae" "$ie") ))
      fi
      # CPU: the cgroup counter for this invocation of the unit
      local pc=${prev[$unit.cpu]:-} pi=${prev[$unit.inv]:-}
      [[ -z $last_us ]] && pc=""
      cpu=$(( cpu + $(meter_delta "$pc" "$cpu_ns" "$([[ $inv == "$pi" ]] && echo same || echo new)") ))
      next+="$unit.cpu $cpu_ns"$'\n'"$unit.inv ${inv:--}"$'\n'
      # egress: what the sandbox sent out of its own link (gvisor apps only)
      local nic="/sys/class/net/hpv$port" rx=0 idx=-
      [[ -e $nic ]] || nic="/sys/class/net/hpvw$port"
      if [[ -r $nic/statistics/rx_bytes ]]; then rx=$(cat "$nic/statistics/rx_bytes"); idx=$(cat "$nic/ifindex"); fi
      local pr=${prev[$unit.rx]:-} px=${prev[$unit.idx]:-}
      [[ -z $last_us ]] && pr=""
      [[ $idx == - ]] && pr=""
      egress=$(( egress + $(meter_delta "$pr" "$rx" "$([[ $idx == "$px" ]] && echo same || echo new)") ))
      next+="$unit.rx $rx"$'\n'"$unit.idx $idx"$'\n'
    done <<<"$insts"
    if [[ -n $last_us ]] && (( awake > 0 || cpu > 0 || egress > 0 )); then
      meter_append "$(meter_record __SEQ__ "$last_unix" "$now_unix" "$app" "$mem" $(( awake / 1000 )) $(( cpu / 1000000 )) "$egress")"
    fi
  done
  printf '%s' "$next" > "$METER_DIR/state.tmp" && mv "$METER_DIR/state.tmp" "$METER_DIR/state"
}

cmd_meter_read() { [[ ${1:-0} =~ ^[0-9]{1,18}$ ]] || die "meter-read: invalid sequence"; meter_read "${1:-0}"; }
cmd_meter_ack()  { [[ ${1:-} =~ ^[0-9]{1,18}$ ]] || die "meter-ack: invalid sequence"; _meter_lock; meter_ack "$1"; echo "acked $1"; }

# meter_gate_decision <orig> — the control plane's meter certificate: read and
# confirm usage, nothing else (not even status — it sees no app).
meter_gate_decision() {
  local orig=${1:-}
  [[ -n $orig ]] || { echo "deny interactive access is not permitted"; return; }
  local -a a; read -ra a <<<"$orig"
  local off
  if [[ ${a[0]:-} == sudo && ${a[1]:-} == /usr/local/bin/homeportd ]]; then off=2
  elif [[ ${a[0]:-} == /usr/local/bin/homeportd ]]; then off=1
  else echo "deny may only run homeportd"; return; fi
  case ${a[off]:-} in
    meter-read|meter-ack) [[ ${a[off+1]:-} =~ ^[0-9]{1,18}$ && -z ${a[off+2]:-} ]] || { echo "deny invalid sequence"; return; } ;;
    *) echo "deny verb '${a[off]:-(none)}' is not permitted"; return ;;
  esac
  echo "allow $off"
}

cmd_meter_gate() {
  local orig=${1:-} d
  d=$(meter_gate_decision "$orig")
  if [[ $d == allow\ * ]]; then
    local off=${d#allow }; local -a a; read -ra a <<<"$orig"
    exec /usr/local/bin/homeportd "${a[@]:off}"
  fi
  die "this certificate may only read usage — ${d#deny }"
}

# ensure_meter_timer — the 60s tick, installed with the sandbox runtime
ensure_meter_timer() {
  [[ -f /etc/systemd/system/homeport-meter.timer ]] && return 0
  cat > /etc/systemd/system/homeport-meter.service <<'EOF'
[Unit]
Description=homeport usage meter tick
[Service]
Type=oneshot
ExecStart=/usr/local/bin/homeportd meter-tick
EOF
  cat > /etc/systemd/system/homeport-meter.timer <<'EOF'
[Unit]
Description=homeport usage meter (every minute)
[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
AccuracySec=1s
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now homeport-meter.timer >/dev/null 2>&1 || true
}

# --- pause / resume --------------------------------------------------------------
# The abuse response: stop an app and stop it waking, without deleting
# anything — files, env, releases and its Caddy route stay, and resume
# brings it back exactly as it was. While paused it accrues no usage, and
# add / activate / rollback refuse, so a deploy can't quietly un-pause it.
# The control plane drives this through the app's own cert-gate.

app_paused() { [[ ${PAUSED:-} == 1 ]]; }

die_if_paused() { # <app> — for verbs that would start or reconfigure it
  if grep -qs '^PAUSED=1$' "$HOMEPORT_ETC/$1/config"; then
    die "app '$1' is paused — resume it first"
  fi
}

cmd_pause() {
  local app=${1:-} unit port
  # this app's mode only: nothing left over from another app's config
  local IDLE="" REPLICAS="" AUTOSCALE_MAX="" STATIC="" PAUSED="" PORT=""
  valid_app "$app"
  [[ -f "$HOMEPORT_ETC/$app/config" ]] || die "unknown app '$app'"
  load_app "$app"
  [[ ${STATIC:-} == 1 ]] && die "'$app' is a static site — it has no process to pause"
  # recorded first: from here on nothing may start it again
  _set_config "$app" PAUSED 1
  if [[ -n ${AUTOSCALE_MAX:-} ]]; then
    systemctl disable --now "homeport-$app-autoscale.timer" 2>/dev/null || true
  fi
  if [[ -n ${IDLE:-} ]]; then
    systemctl disable --now "homeport-$app-proxy.socket" 2>/dev/null || true
    systemctl stop "homeport-$app-proxy.service" 2>/dev/null || true
  fi
  while read -r unit port; do
    [[ -n $unit ]] && { systemctl disable --now "$unit" 2>/dev/null || true; }
  done < <(meter_instances "$app")
  echo "paused '$app' — stopped, and nothing will wake it until it's resumed"
}

cmd_resume() {
  local app=${1:-} cfg rest i rbase
  local IDLE="" REPLICAS="" AUTOSCALE_MAX="" STATIC="" PAUSED="" PORT=""
  valid_app "$app"
  cfg="$HOMEPORT_ETC/$app/config"
  [[ -f $cfg ]] || die "unknown app '$app'"
  load_app "$app"
  app_paused || { echo "'$app' is not paused"; return 0; }
  rest=$(grep -v '^PAUSED=' "$cfg" || true)
  printf '%s\n' "$rest" > "$cfg"
  if [[ -n ${IDLE:-} ]]; then
    # scale-to-zero: the socket is back; the app waits for its next request
    systemctl enable --now "homeport-$app-proxy.socket" >/dev/null 2>&1 || true
  elif is_template; then
    rbase=$(replica_base "$PORT")
    for (( i = 1; i <= ${REPLICAS:-1}; i++ )); do
      systemctl enable --now "homeport-$app@$((rbase + i))" >/dev/null 2>&1 || true
    done
    if [[ -n ${AUTOSCALE_MAX:-} ]]; then
      systemctl enable --now "homeport-$app-autoscale.timer" >/dev/null 2>&1 || true
    fi
  else
    systemctl enable --now "homeport-$app" >/dev/null 2>&1 || true
  fi
  echo "resumed '$app'"
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
    for (( i = 1; i <= count; i++ )); do upstreams+=" $(app_addr $((rbase + i))):$((rbase + i))"; done
  else
    upstreams=" $(app_addr "$port"):$port"
  fi
  echo "$upstreams"
}

# emit_reverse_proxy <indent> <mode> <upstreams> — print a reverse_proxy
# directive indented by <indent> (a literal tab string), respecting the app's
# mode. Shared by a plain site block (write_caddy) and a gateway handle_path
# block (write_gateway).
emit_reverse_proxy() {
  local ind=$1 mode=$2 upstreams=$3
  # header_up -X-Origin-Auth: the origin-auth secret proves a request came
  # through our Cloudflare zone; the app never needs it, so it never sees it
  # (and cannot leak it into its logs). Done here rather than with
  # request_header, which Caddy would order before the check and so strip the
  # header the check is looking for.
  case $mode in
    template)
      # lb_try_duration retries a request that hit a down/restarting replica on
      # a live upstream — what makes rolling deploys/scaling zero-downtime.
      printf '%sreverse_proxy%s {\n%s\theader_up -X-Origin-Auth\n%s\tlb_policy least_conn\n%s\tlb_try_duration 4s\n%s\tlb_try_interval 250ms\n%s\tfail_duration 10s\n%s}\n' "$ind" "$upstreams" "$ind" "$ind" "$ind" "$ind" "$ind" "$ind" ;;
    idle)
      # keepalive off so Caddy doesn't hold socket-proxyd open past idle.
      printf '%sreverse_proxy%s {\n%s\theader_up -X-Origin-Auth\n%s\ttransport http {\n%s\t\tkeepalive off\n%s\t}\n%s}\n' "$ind" "$upstreams" "$ind" "$ind" "$ind" "$ind" "$ind" ;;
    *)
      printf '%sreverse_proxy%s {\n%s\theader_up -X-Origin-Auth\n%s}\n' "$ind" "$upstreams" "$ind" "$ind" ;;
  esac
}

# app_mode — echo the Caddy proxy mode for the loaded app's config vars.
app_mode() {
  if [[ ${REPLICAS:-1} -gt 1 || -n ${AUTOSCALE_MAX:-} ]]; then echo template
  elif [[ -n ${IDLE:-} ]]; then echo idle
  else echo plain; fi
}

# validate_headers <b64> — decode and check the app's user-configured response
# headers; die on bad encoding or an unsafe name/value. THE SECURITY GATE: these
# values are emitted verbatim into a generated Caddyfile, so anything that could
# break out of it (CRLF, quotes, braces, backslashes) is rejected. Runs in the
# current shell (not a $() subshell) so die() actually aborts the command.
validate_headers() {
  local b64=$1 decoded glob name val
  [[ -n $b64 && $b64 != - ]] || return 0
  decoded=$(printf %s "$b64" | base64 -d 2>/dev/null) || die "headers: invalid encoding"
  while IFS=$'\t' read -r glob name val; do
    [[ -n $glob ]] || continue
    [[ $glob == '*' || $glob =~ ^/[A-Za-z0-9._*/~-]*$ ]] || die "headers: invalid path '$glob'"
    [[ $glob != *..* ]] || die "headers: path may not contain '..'"
    [[ $name =~ ^[A-Za-z0-9-]+$ ]] || die "headers: invalid name '$name'"
    [[ $val =~ ^[[:print:]]*$ ]] || die "headers: unsafe value for header '$name'"
    case $val in *'"'*|*'\'*|*'{'*|*'}'*) die "headers: unsafe value for header '$name'";; esac
  done <<< "$decoded"
}

# emit_user_headers <indent> — print Caddy header blocks for $HEADERS_B64
# (pre-validated). Records are "glob<TAB>name<TAB>value", sorted so one glob's
# headers are contiguous. "/*" (or "*") → a global `header { }`; any other glob →
# a path matcher `@N path <glob>` + `header @N { }`. homeport sets NO headers on
# its own — this emits only what the app owner configured.
emit_user_headers() {
  local ind=$1 decoded glob name val prev="" i=0 open=0 slug
  [[ -n ${HEADERS_B64:-} && ${HEADERS_B64} != - ]] || return 0
  decoded=$(printf %s "$HEADERS_B64" | base64 -d 2>/dev/null) || return 0
  while IFS=$'\t' read -r glob name val; do
    [[ -n $glob ]] || continue
    if [[ $glob != "$prev" ]]; then
      [[ $open == 1 ]] && printf '%s}\n' "$ind"
      if [[ $glob == '*' || $glob == '/*' ]]; then
        printf '%sheader {\n' "$ind"
      else
        slug="hp$i"; i=$((i + 1))
        printf '%s@%s path %s\n' "$ind" "$slug" "$glob"
        printf '%sheader @%s {\n' "$ind" "$slug"
      fi
      open=1; prev=$glob
    fi
    printf '%s\t%s "%s"\n' "$ind" "$name" "$val"
  done <<< "$decoded"
  [[ $open == 1 ]] && printf '%s}\n' "$ind"
}

# emit_tls <indent> <app> — when the app uses a bring-your-own cert
# (TLS_MODE=manual), tell Caddy to serve it instead of provisioning one via ACME
# (which can't work behind a TLS-terminating proxy like Cloudflare). homeport
# never does this on its own — the operator uploads the cert with
# `homeport tls set`, which cmd_tls_set validates and stores.
# caddy_validate [binary] — validate the Caddyfile with Caddy's env vars
# loaded: DNS-provider modules provision at load time and reject a missing
# token, and the systemd EnvironmentFile only applies to the service, not CLI
# runs. The env file is passed via env(1) argv — never sourced (its values are
# data; sourcing a secrets file would execute it).
caddy_validate() {
  local bin=${1:-caddy} line
  local -a envargs=()
  if [[ -f $CADDY_ENV_FILE ]]; then
    while IFS= read -r line; do [[ -n $line ]] && envargs+=("$line"); done < "$CADDY_ENV_FILE"
  fi
  env ${envargs[@]+"${envargs[@]}"} "$bin" validate --config "$CADDYFILE" >/dev/null 2>&1
}

# validate_tls_mode <app> <mode> <token_env> — gate the tls positional args.
# manual without a cert and dns without a token are allowed at registration
# (chicken/egg: both are uploaded per-server AFTER the app exists or before —
# order-free), but each gets a loud warning. A dns: mode without its Caddy
# plugin is a hard error: the generated Caddyfile would fail validation anyway,
# so fail here with an actionable message instead.
validate_tls_mode() {
  local app=$1 mode=$2 tokenv=$3 provider
  [[ -z $tokenv || $tokenv == none || $tokenv =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] \
    || die "tls: dns_token_env '$tokenv' is not a valid env var name"
  case $mode in
    "") : ;;
    manual)
      [[ -f "$TLS_CERT_DIR/$app/cert.pem" ]] \
        || echo "tls: manual is set but no cert is uploaded yet — serving automatic HTTPS until you run 'homeport tls set <cert> <key>'" >&2
      ;;
    dns:*)
      provider=${mode#dns:}
      [[ $provider =~ ^[a-z0-9-]{1,40}$ ]] || die "tls: invalid dns provider '$provider'"
      caddy_has_module "dns.providers.$provider" \
        || die "tls: caddy has no '$provider' DNS module — install it first: homeport server plugins add github.com/caddy-dns/$provider"
      [[ -n $tokenv ]] || tokenv=$(dns_default_env "$provider")
      if [[ $tokenv != none ]] && ! grep -qs "^$tokenv=" "$CADDY_ENV_FILE"; then
        echo "tls: env var '$tokenv' is not set for caddy — cert issuance will fail until you run 'homeport server caddy-env $tokenv'" >&2
      fi
      ;;
    *) die "tls: mode must be 'manual' or 'dns:<provider>', got '$mode'" ;;
  esac
}

# caddy_has_module <exact-module-id> — SIGPIPE-safe module check. `list-modules
# | grep -q` is a RACE under pipefail: grep exits on first match, caddy gets
# SIGPIPE mid-write, the pipeline reports 141 — a transient false "no module"
# we hit live. Capture first, match a herestring.
caddy_has_module() {
  local mods
  mods=$(caddy list-modules 2>/dev/null) || true
  grep -q "^${1}\$" <<< "$mods"
}

# dns_default_env <provider> — the uniform token env var name for a provider
# (Caddy resolves {env.X} itself, so the name is homeport's choice, not the
# plugin's): dns:cloudflare -> HOMEPORT_DNS_CLOUDFLARE.
dns_default_env() {
  # tr, not ${1^^}: keeps the function testable on bash 3.2 (macOS)
  printf 'HOMEPORT_DNS_%s' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
}

emit_tls() {
  local ind=$1 app=$2
  case ${TLS_MODE:-} in
    manual)
      # both conditions: mode is manual AND the cert is actually uploaded — a
      # tls directive pointing at missing files would fail Caddyfile validation
      # and block every app's reload. Until then, auto-TLS keeps serving.
      [[ -f "$TLS_CERT_DIR/$app/cert.pem" ]] || return 0
      printf '%stls %s/%s/cert.pem %s/%s/key.pem\n' "$ind" "$TLS_CERT_DIR" "$app" "$TLS_CERT_DIR" "$app"
      ;;
    dns:*)
      # DNS-01 via a caddy-dns plugin — works behind a TLS-terminating proxy.
      # The token reaches the plugin through a Caddy {env.X} placeholder; the
      # env var itself is loaded via caddy-env-set (systemd EnvironmentFile).
      local provider=${TLS_MODE#dns:} tokenv=${TLS_DNS_ENV:-}
      [[ -n $tokenv ]] || tokenv=$(dns_default_env "$provider")
      printf '%stls {\n' "$ind"
      if [[ $tokenv == none ]]; then
        printf '%s\tdns %s\n' "$ind" "$provider"   # provider reads SDK env vars itself
      else
        printf '%s\tdns %s {env.%s}\n' "$ind" "$provider" "$tokenv"
      fi
      printf '%s}\n' "$ind"
      ;;
  esac
}

# emit_redirect_from <app> <primary> — one tiny site block per alias domain in
# $REDIRECT_FROM (comma list): a 301 to the primary, path preserved. Lives in
# the app's own fragment so aliases are created/updated/removed with the app.
# Aliases inherit the app's TLS mode (a CF origin cert or same-zone DNS-01
# covers them; with auto, Caddy just issues a cert per alias).
emit_redirect_from() {
  local app=$1 primary=$2 alias
  [[ -n ${REDIRECT_FROM:-} ]] || return 0
  local IFS=','
  for alias in $REDIRECT_FROM; do
    [[ -n $alias ]] || continue
    printf '%s {\n' "$alias"
    emit_tls $'\t' "$app"
    # route keeps written order: Caddy sorts redir BEFORE abort, so outside a
    # route the origin check would run after the redirect was already sent.
    printf '\troute {\n'
    emit_origin_auth $'\t\t'
    printf '\t\tredir https://%s{uri} permanent\n' "$primary"
    printf '\t}\n}\n'
  done
}

# host_owned_by <host> <exclude-app> — echo the app (if any) that already owns
# <host> as its domain, a serving alias, or a redirect alias.
host_owned_by() {
  local host=$1 exclude=$2 _cfg _oapp v
  for _cfg in "$HOMEPORT_ETC"/*/config; do
    [[ -f $_cfg && $_cfg != "$HOMEPORT_ETC/$exclude/config" ]] || continue
    _oapp=$(basename "$(dirname "$_cfg")")
    v=$(sed -n 's/^DOMAIN=//p' "$_cfg")
    [[ $v == "$host" ]] && { echo "$_oapp"; return; }
    v=$(sed -n 's/^ALIASES=//p' "$_cfg")
    [[ ",$v," == *",$host,"* ]] && { echo "$_oapp"; return; }
    v=$(sed -n 's/^REDIRECT_FROM=//p' "$_cfg")
    [[ ",$v," == *",$host,"* ]] && { echo "$_oapp"; return; }
  done
  return 0   # not found is the NORMAL case — callers read the echo, not the status
}

# host_alias_owner <host> <exclude-app> — like host_owned_by but only scans the
# alias lists (a primary DOMAIN match is handled separately by the add paths,
# which have gateway-sharing semantics for it).
host_alias_owner() {
  local host=$1 exclude=$2 _cfg _oapp v
  for _cfg in "$HOMEPORT_ETC"/*/config; do
    [[ -f $_cfg && $_cfg != "$HOMEPORT_ETC/$exclude/config" ]] || continue
    _oapp=$(basename "$(dirname "$_cfg")")
    v=$(sed -n 's/^ALIASES=//p' "$_cfg")
    [[ ",$v," == *",$host,"* ]] && { echo "$_oapp"; return; }
    v=$(sed -n 's/^REDIRECT_FROM=//p' "$_cfg")
    [[ ",$v," == *",$host,"* ]] && { echo "$_oapp"; return; }
  done
  return 0   # not found is the NORMAL case — callers read the echo, not the status
}

# validate_extra_hosts <app> <primary> <csv> <label> — shared checks for the
# aliases/redirect_from lists: each entry must look like a domain, differ from
# the primary, and not be owned by any other app on the box (as its domain, a
# serving alias, or a redirect alias).
validate_extra_hosts() {
  local app=$1 primary=$2 csv=$3 label=$4 alias owner
  [[ -n $csv ]] || return 0
  local IFS=','
  for alias in $csv; do
    [[ -n $alias ]] || continue
    valid_domain "$alias"
    [[ $alias != "$primary" ]] || die "$label: '$alias' is the app's own domain"
    owner=$(host_owned_by "$alias" "$app")
    [[ -z $owner ]] || die "$label: '$alias' is already used by app '$owner'"
  done
}

# --- origin auth -------------------------------------------------------------
# A firewall that allows Cloudflare's ranges proves a request came via
# Cloudflare — not via OUR zone: those ranges are shared by every customer, and
# anyone can point their own proxied hostname at this IP and override Host.
# A secret header injected by a Transform Rule on our zone proves the rest.
#
# Every public site imports one snippet, defined in a file that sorts before
# every app fragment. It is empty while origin auth is off, so every import
# always resolves and turning it on or off rewrites one file.
ORIGIN_AUTH_FRAG=$CADDY_DIR/00-origin-auth.caddy

# emit_origin_auth <indent> — the check, as the first line of a site block or
# of a handle block. Gateways need it INSIDE each handle: Caddy runs
# handle/handle_path before a site-level abort, so a site-level check there
# would run after the request had already been proxied.
emit_origin_auth() { printf '%simport homeport_origin_auth\n' "$1"; }

# origin_auth_snippet <secret|""> [previous] — the snippet definition. Two
# values = a rotation in progress, accepted either way while the Cloudflare
# rule is switched over. Lines in a matcher block are ANDed, so "not A, not B"
# drops a request only when it carries neither. (The one-line header matcher
# takes a single value.)
origin_auth_snippet() {
  printf '# managed by homeport — edit via `homeport server origin-auth`\n'
  printf '(homeport_origin_auth) {\n'
  if [[ -n ${1:-} ]]; then
    printf '\t@homeport_origin_unauthenticated {\n'
    printf '\t\tnot header X-Origin-Auth "%s"\n' "$1"
    [[ -n ${2:-} ]] && printf '\t\tnot header X-Origin-Auth "%s"\n' "$2"
    printf '\t}\n'
    printf '\tabort @homeport_origin_unauthenticated\n'
  fi
  printf '}\n'
}

# origin_auth_values — the accepted values in a snippet on stdin, one per line,
# newest first. The snippet is ours and its values are charset-validated, so a
# plain match is exact.
origin_auth_values() {
  sed -n 's/^[[:space:]]*not header X-Origin-Auth "\([A-Za-z0-9_-]*\)"$/\1/p'
}

# valid_origin_secret <s> — the secret is written into a Caddyfile, so the
# charset is closed: nothing that could end a quote or a block. 32–128 chars.
valid_origin_secret() {
  [[ ${1:-} =~ ^[A-Za-z0-9_-]{32,128}$ ]] || die "origin-auth secret must be 32–128 characters of A-Z a-z 0-9 _ -"
}

# ensure_origin_auth_snippet — make sure the snippet exists (as "off" if never
# set), so a freshly rendered site's import resolves on boxes that predate it.
ensure_origin_auth_snippet() {
  [[ -d $CADDY_DIR && ! -f $ORIGIN_AUTH_FRAG ]] || return 0
  origin_auth_snippet "" > "$ORIGIN_AUTH_FRAG"
}

# origin_auth_on — is enforcement on? The snippet file is the only state.
origin_auth_on() { [[ -n $(origin_auth_values < "$ORIGIN_AUTH_FRAG" 2>/dev/null) ]]; }

# _origin_auth_apply <secret|""> — write the snippet, re-render every public
# site (fragments written before this feature existed have no import line),
# validate, and reload — or restore every fragment and die. All-or-nothing: a
# half-applied change would leave some sites open and others unreachable.
_origin_auth_apply() {
  local secret=$1 msg=$2 prev=${3:-} snap cfg app
  snap=$(mktemp -d)
  cp -p "$CADDY_DIR"/*.caddy "$snap"/ 2>/dev/null || true
  origin_auth_snippet "$secret" "$prev" > "$ORIGIN_AUTH_FRAG"
  # 640 root:caddy — the secret is a credential; only caddy needs to read it.
  chown root:caddy "$ORIGIN_AUTH_FRAG"; chmod 640 "$ORIGIN_AUTH_FRAG"
  for cfg in "$HOMEPORT_ETC"/*/config; do
    [[ -f $cfg ]] || continue
    app=$(basename "$(dirname "$cfg")")
    # subshell: load_app sets globals (ALIASES, TLS_MODE…) that must not leak
    # from one app into the next one's render.
    ( load_app "$app"; [[ -n ${DOMAIN:-} ]] || exit 0; rewrite_app_caddy "$app" ) \
      || { _origin_auth_restore "$snap"; die "origin-auth: re-rendering '$app' failed — rolled back"; }
  done
  if ! caddy_validate; then
    _origin_auth_restore "$snap"
    die "origin-auth: generated Caddy config failed validation — rolled back, nothing changed"
  fi
  rm -rf "$snap"
  systemctl reload caddy
  echo "$msg"
}

_origin_auth_restore() {
  local snap=$1
  rm -f "$CADDY_DIR"/*.caddy
  cp -p "$snap"/*.caddy "$CADDY_DIR"/ 2>/dev/null || true
  rm -rf "$snap"
}

# cmd_origin_auth_set [--keep-previous] — secret on stdin (never argv: it would
# show in ps and in the SSH command line). Once on, EVERY public site on this
# box drops a request without the header — so add the Transform Rule at
# Cloudflare first. To rotate without dropping traffic: set the new value with
# --keep-previous (both accepted), switch the Cloudflare rule, then retire.
cmd_origin_auth_set() {
  local secret prev=""
  secret=$(head -c 256 | tr -d '\r\n')
  valid_origin_secret "$secret"
  if [[ ${1:-} == --keep-previous ]]; then
    prev=$(origin_auth_values < "$ORIGIN_AUTH_FRAG" | head -1)
    [[ -n $prev ]] || die "origin-auth is off — there is no previous value to keep"
    [[ $prev != "$secret" ]] || die "that is already the current value"
    _origin_auth_apply "$secret" "origin-auth: rotating — the new AND the previous value are accepted. Switch the Cloudflare rule, then: homeport server origin-auth retire" "$prev"
    return
  fi
  [[ -z ${1:-} ]] || die "usage: origin-auth-set [--keep-previous] (secret on stdin)"
  _origin_auth_apply "$secret" "origin-auth: on — requests without the X-Origin-Auth header are now dropped"
}

# cmd_origin_auth_retire — end a rotation: accept only the newest value.
cmd_origin_auth_retire() {
  local cur
  cur=$(origin_auth_values < "$ORIGIN_AUTH_FRAG" | head -1)
  [[ -n $cur ]] || die "origin-auth is off — nothing to retire"
  [[ $(origin_auth_values < "$ORIGIN_AUTH_FRAG" | wc -l) -gt 1 ]] || { echo "origin-auth: no rotation in progress — nothing to retire"; return 0; }
  _origin_auth_apply "$cur" "origin-auth: previous value retired — only the new one is accepted"
}

cmd_origin_auth_clear() {
  _origin_auth_apply "" "origin-auth: off — public sites accept any request that reaches them"
}

# cmd_origin_auth_status — on/off only. The value never leaves the box.
cmd_origin_auth_status() {
  local n
  n=$(origin_auth_values < "$ORIGIN_AUTH_FRAG" 2>/dev/null | wc -l | tr -d ' ')
  if [[ $n -gt 1 ]]; then echo "origin-auth: on — rotation in progress ($n values accepted; finish with: homeport server origin-auth retire)"
  elif [[ $n -eq 1 ]]; then echo "origin-auth: on"
  else echo "origin-auth: off"; fi
}

# write_caddy <app> <domain> <port> <mode> <count> — (re)write an app's Caddy
# fragment (a whole-host site block). mode: template | idle | plain.
# Used by cmd_add and the autoscaler (which rewrites on every scale event).
write_caddy() {
  local app=$1 domain=$2 port=$3 mode=$4 count=${5:-1} upstreams hosts
  upstreams=$(app_upstreams "$port" "$mode" "$count")
  # serving aliases share the site block: "a.com, b.com { … }" — Caddy issues
  # a cert per hostname automatically.
  hosts=$domain
  [[ -n ${ALIASES:-} ]] && hosts="$domain, ${ALIASES//,/, }"
  { printf '%s {\n\tencode zstd gzip\n' "$hosts"
    emit_origin_auth $'\t'
    emit_tls $'\t' "$app"
    emit_user_headers $'\t'
    emit_reverse_proxy $'\t' "$mode" "$upstreams"
    printf '}\n'
    emit_redirect_from "$app" "$domain"
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
  local app=$1 domain=$2 spa=$3 fallback="" hosts
  [[ $spa == 1 ]] && fallback=" /200.html /index.html"
  hosts=$domain
  [[ -n ${ALIASES:-} ]] && hosts="$domain, ${ALIASES//,/, }"
  { printf '%s {\n' "$hosts"
    printf '\tencode zstd gzip\n'
    emit_origin_auth $'\t'
    emit_tls $'\t' "$app"
    emit_user_headers $'\t'
    printf '\troot * %s/%s/current\n' "$HOMEPORT_ROOT" "$app"
    printf '\ttry_files {path} {path}.html {path}/%s\n' "$fallback"
    printf '\tfile_server\n'
    printf '}\n'
    emit_redirect_from "$app" "$domain"
  } > "$CADDY_DIR/$app.caddy"
}

# cmd_add_static <app> <domain> <spa> — register a static site: a Caddy
# file_server on its own domain, no systemd unit, no app user, no port bound.
cmd_add_static() {
  local app=$1 domain=$2 spa=${3:-} headers_b64=${4:-} tls_mode=${5:-} tls_dns_env=${6:-} redirect_from=${7:-} aliases=${8:-}
  [[ $domain == - || -z $domain ]] && die "a static site needs a domain"
  valid_domain "$domain"
  [[ $headers_b64 == - ]] && headers_b64=""
  [[ $tls_mode == - ]] && tls_mode=""
  [[ $tls_dns_env == - ]] && tls_dns_env=""
  [[ $redirect_from == - ]] && redirect_from=""
  [[ $aliases == - ]] && aliases=""
  validate_headers "$headers_b64"
  validate_tls_mode "$app" "$tls_mode" "$tls_dns_env"
  validate_extra_hosts "$app" "$domain" "$redirect_from" "redirect_from"
  validate_extra_hosts "$app" "$domain" "$aliases" "aliases"
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
  local _aowner
  _aowner=$(host_alias_owner "$domain" "$app")
  [[ -z $_aowner ]] || die "domain $domain is already an alias of app '$_aowner'"

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
HEADERS_B64=$headers_b64
TLS_MODE=$tls_mode
TLS_DNS_ENV=$tls_dns_env
REDIRECT_FROM=$redirect_from
ALIASES=$aliases
EOF
  # fresh values for emit_user_headers/emit_tls — load_app (above, for an
  # existing app) would have sourced the OLD values over them.
  HEADERS_B64=$headers_b64 TLS_MODE=$tls_mode TLS_DNS_ENV=$tls_dns_env REDIRECT_FROM=$redirect_from ALIASES=$aliases
  # fragment write is transactional: a fragment that fails validation must not
  # stay on disk, or the NEXT caddy restart (any restart!) fails to boot.
  local _frag="$CADDY_DIR/$app.caddy" _fragbak="" _hadfrag=0
  [[ -f $_frag ]] && { _fragbak=$(cat "$_frag"); _hadfrag=1; }
  write_caddy_static "$app" "$domain" "$spa"
  if ! caddy_validate; then
    if [[ $_hadfrag == 1 ]]; then printf '%s' "$_fragbak" > "$_frag"; else rm -f "$_frag"; fi
    die "generated Caddy config failed validation — rolled back"
  fi
  systemctl reload caddy
  echo "app '$app' registered (static${spa:+, SPA}) -> https://$domain"
  echo "DNS: point an A record for $domain to $(public_ip) — TLS is automatic once it resolves"
}

# _set_config <app> <key> <value> — set KEY=value in the app's config, replacing
# an existing line or appending. Values here are homeportd-controlled (no user
# metacharacters), so a plain sed replace is safe.
_set_config() {
  local cfg="$HOMEPORT_ETC/$1/config" key=$2 val=$3
  if grep -q "^$key=" "$cfg" 2>/dev/null; then
    sed -i "s|^$key=.*|$key=$val|" "$cfg"
  else
    printf '%s=%s\n' "$key" "$val" >> "$cfg"
  fi
}

# rewrite_app_caddy <app> — regenerate one app's Caddy fragment from its saved
# config (used after tls set/clear). Picks the static / gateway / whole-host
# writer; each re-reads TLS_MODE via load_app.
rewrite_app_caddy() {
  local app=$1
  load_app "$app"
  if [[ ${STATIC:-} == 1 ]]; then
    write_caddy_static "$app" "$DOMAIN" "${SPA:-}"
  elif [[ -n ${PATH_PREFIX:-} ]]; then
    write_gateway "$DOMAIN"
  else
    write_caddy "$app" "$DOMAIN" "$PORT" "$(app_mode)" "${REPLICAS:-1}"
  fi
}

# cmd_tls_set <app> — install a bring-your-own TLS cert for a public app. Reads
# "cert-PEM \n ##HOMEPORT_TLS_KEY## \n key-PEM" from stdin (the CLI concatenates
# them; the key never travels via argv). Validates, stores caddy-readable, flips
# the app to TLS_MODE=manual and reloads Caddy. homeport sets no cert on its own.
cmd_tls_set() {
  local app=${1:-}
  valid_app "$app"
  [[ -f "$HOMEPORT_ETC/$app/config" ]] || die "unknown app '$app'"
  load_app "$app"
  [[ -n ${DOMAIN:-} ]] || die "app '$app' is internal (no domain) — nothing to serve a cert for"
  [[ -z ${PATH_PREFIX:-} ]] || die "app '$app' is path-mounted — its gateway host owns TLS"
  # 1 MiB cap: a full chain + key is a few KB; anything bigger is a mistake (or
  # a memory-exhaustion attempt) — same spirit as the upload size cap.
  local blob cert key sep=$'\n''##HOMEPORT_TLS_KEY##'$'\n'
  blob=$(head -c 1048576)
  [[ $blob == *"$sep"* ]] || die "tls: malformed upload (missing cert/key separator)"
  cert=${blob%%"$sep"*}
  key=${blob#*"$sep"}
  [[ $cert == *"-----BEGIN CERTIFICATE-----"* ]] || die "tls: first part is not a PEM certificate"
  [[ $key == *"-----BEGIN "*"PRIVATE KEY-----"* ]] || die "tls: second part is not a PEM private key"
  # everything below is transactional: back up the current certs, fragment and
  # mode, and restore ALL of them if the new cert fails Caddy validation —
  # otherwise a bad upload would leave an invalid Caddyfile that blocks every
  # app's reload on this box.
  local certdir="$TLS_CERT_DIR/$app" frag="$CADDY_DIR/$app.caddy"
  local old_mode=${TLS_MODE:-} fragbak="" hadfrag=0
  [[ -f $frag ]] && { fragbak=$(cat "$frag"); hadfrag=1; }
  rm -rf "$certdir.bak"; [[ -d $certdir ]] && cp -a "$certdir" "$certdir.bak"
  install -d -m 750 -o caddy -g caddy "$certdir"
  ( umask 077
    printf '%s\n' "$cert" > "$certdir/cert.pem"
    printf '%s\n' "$key"  > "$certdir/key.pem"
  )
  chown caddy:caddy "$certdir/cert.pem" "$certdir/key.pem"
  chmod 644 "$certdir/cert.pem"
  chmod 600 "$certdir/key.pem"
  _set_config "$app" TLS_MODE manual
  rewrite_app_caddy "$app"   # re-sources the config, which now says manual
  if ! caddy_validate; then
    rm -rf "$certdir"
    [[ -d $certdir.bak ]] && mv "$certdir.bak" "$certdir"
    _set_config "$app" TLS_MODE "$old_mode"
    [[ $hadfrag == 1 ]] && printf '%s' "$fragbak" > "$frag"
    die "tls: cert failed Caddy validation — nothing changed (is it a valid cert/key pair for $DOMAIN?)"
  fi
  rm -rf "$certdir.bak"
  systemctl reload caddy
  echo "tls: manual cert installed for '$app' ($DOMAIN)"
}

# cmd_tls_clear <app> — remove the manual cert and revert to automatic HTTPS.
cmd_tls_clear() {
  local app=${1:-}
  valid_app "$app"
  [[ -f "$HOMEPORT_ETC/$app/config" ]] || die "unknown app '$app'"
  rm -rf "${TLS_CERT_DIR:?}/$app"
  _set_config "$app" TLS_MODE ""
  rewrite_app_caddy "$app"
  caddy_validate \
    || die "generated Caddy config failed validation"
  systemctl reload caddy
  echo "tls: reverted '$app' to automatic HTTPS (Let's Encrypt)"
}

# ---------------------------------------------------------------------------
# Caddy plugins — swap /usr/bin/caddy for a build from Caddy's OFFICIAL build
# service (caddyserver.com/api/download) that includes the requested plugin
# modules. Nothing compiles on this box (xcaddy would need a Go toolchain);
# the project's build farm compiles, we download over HTTPS and verify. The
# apt-installed binary is preserved via dpkg-divert, so removing every plugin
# restores stock Caddy and its apt security-upgrade path.
# ---------------------------------------------------------------------------
CADDY_PLUGINS_FILE=/etc/homeport/caddy-plugins

# valid_caddy_module <module> — a Go module repo path (github.com/caddy-dns/…).
# Strict charset: these become URL query values and argv, so anything that
# could smuggle a second URL parameter or path traversal is rejected.
valid_caddy_module() {
  local m=${1:-}
  [[ -n $m && ${#m} -le 200 ]] || return 1
  [[ $m != *..* ]] || return 1
  [[ $m =~ ^[a-z0-9][a-zA-Z0-9._-]*(/[a-zA-Z0-9._-]+)+$ ]]
}

_caddy_plugin_list() { [[ -f $CADDY_PLUGINS_FILE ]] && cat "$CADDY_PLUGINS_FILE" || true; }

# _caddy_restore_stock — undo the diversion: put the apt-managed binary back.
_caddy_restore_stock() {
  rm -f /usr/bin/caddy /usr/bin/caddy.homeport-prev
  dpkg-divert --rename --remove /usr/bin/caddy >/dev/null 2>&1 || true
  rm -f "$CADDY_PLUGINS_FILE"
}

# _caddy_rebuild <module>... — download a build with exactly these modules,
# verify it, swap it in, restart Caddy; roll back to the previous binary if
# Caddy doesn't come back healthy. With NO modules, restore the stock binary.
_caddy_rebuild() {
  if [[ $# -eq 0 ]]; then
    _caddy_restore_stock
    systemctl restart caddy
    sleep 2
    systemctl is-active --quiet caddy || die "stock caddy failed to start after restore — check 'journalctl -u caddy'"
    echo "caddy: restored stock binary (apt-managed, no plugins)"
    return
  fi
  local arch m url tmp
  arch=$(dpkg --print-architecture)
  [[ $arch == amd64 || $arch == arm64 ]] || die "unsupported architecture '$arch'"
  url="https://caddyserver.com/api/download?os=linux&arch=$arch"
  for m in "$@"; do url+="&p=$m"; done
  tmp=$(mktemp /usr/bin/.caddy-download.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  echo "caddy: downloading a build with $# plugin(s) from caddyserver.com…"
  curl -fsSL --proto '=https' --max-time 300 "$url" -o "$tmp" \
    || die "download from Caddy's build service failed"
  chmod 755 "$tmp"
  "$tmp" version >/dev/null 2>&1 || die "downloaded binary does not run"
  local binfo
  binfo=$("$tmp" build-info 2>/dev/null) || true
  for m in "$@"; do
    grep -qF "$m" <<< "$binfo" \
      || die "downloaded binary does not contain '$m' (typo in the module path?)"
  done
  caddy_validate "$tmp" \
    || die "current Caddyfile fails validation under the new binary — not installed"
  # first swap: divert the apt binary aside so upgrades don't clobber ours
  dpkg-divert --list /usr/bin/caddy 2>/dev/null | grep -q 'caddy\.default' \
    || dpkg-divert --divert /usr/bin/caddy.default --rename --add /usr/bin/caddy >/dev/null
  [[ -f /usr/bin/caddy ]] && cp -a /usr/bin/caddy /usr/bin/caddy.homeport-prev
  install -m 755 "$tmp" /usr/bin/caddy
  systemctl restart caddy
  sleep 2
  if ! systemctl is-active --quiet caddy; then
    # roll back: previous custom binary if there was one, else the stock one
    if [[ -f /usr/bin/caddy.homeport-prev ]]; then
      install -m 755 /usr/bin/caddy.homeport-prev /usr/bin/caddy
    else
      _caddy_restore_stock
    fi
    systemctl restart caddy
    die "caddy failed to start with the new build — rolled back (check 'journalctl -u caddy')"
  fi
  printf '%s\n' "$@" > "$CADDY_PLUGINS_FILE"
}

cmd_caddy_plugin_add() {
  [[ $# -ge 1 ]] || die "usage: caddy-plugin-add <module> [module...]"
  local m c seen current=() want=()
  for m in "$@"; do valid_caddy_module "$m" || die "invalid plugin module '$m' (expected a repo path like github.com/caddy-dns/cloudflare)"; done
  mapfile -t current < <(_caddy_plugin_list)
  want=("${current[@]}")
  for m in "$@"; do
    seen=0
    for c in "${want[@]}"; do [[ $c == "$m" ]] && seen=1; done
    [[ $seen == 1 ]] && { echo "caddy: '$m' already installed"; continue; }
    want+=("$m")
  done
  [[ ${#want[@]} -gt ${#current[@]} ]] || return 0
  _caddy_rebuild "${want[@]}"
  echo "caddy: now running with plugins:"; printf '  %s\n' "${want[@]}"
  echo "note: this binary is no longer upgraded by apt — re-run a plugin add to refresh it"
}

cmd_caddy_plugin_rm() {
  [[ $# -eq 1 ]] || die "usage: caddy-plugin-rm <module>"
  local m=$1 c keep=() found=0
  valid_caddy_module "$m" || die "invalid plugin module '$m'"
  while IFS= read -r c; do
    [[ -n $c ]] || continue
    if [[ $c == "$m" ]]; then found=1; else keep+=("$c"); fi
  done < <(_caddy_plugin_list)
  [[ $found == 1 ]] || die "plugin '$m' is not installed (caddy-plugin-list to see them)"
  _caddy_rebuild "${keep[@]}"
  if [[ ${#keep[@]} -gt 0 ]]; then
    echo "caddy: now running with plugins:"; printf '  %s\n' "${keep[@]}"
  fi
}

cmd_caddy_plugin_list() {
  local plugins
  plugins=$(_caddy_plugin_list)
  if [[ -z $plugins ]]; then
    echo "stock caddy (apt-managed, no extra plugins)"
  else
    printf '%s\n' "$plugins"
  fi
}

# ---------------------------------------------------------------------------
# Web-ingress firewall — restrict ports 80/443 to a set of CIDR ranges (e.g.
# Cloudflare's published IPs) so a known origin IP can't be hit directly,
# bypassing the edge's WAF/DDoS protection. Declarative: the uploaded list IS
# the policy; clear restores the bootstrap default (open to the world). SSH is
# never touched — a bad policy can only break web traffic, not lock you out.
# ---------------------------------------------------------------------------
FIREWALL_WEB_FILE=/etc/homeport/firewall-web

# valid_cidr <cidr> — IPv4 (octets 0-255, mask 0-32) or IPv6 (mask 0-128).
# These become ufw argv, so anything else is rejected.
valid_cidr() {
  local c=${1:-}
  if [[ $c =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
    local i
    for i in "${BASH_REMATCH[@]:1:4}"; do (( i <= 255 )) || return 1; done
    (( BASH_REMATCH[5] <= 32 )) || return 1
    return 0
  fi
  [[ $c == *:* ]] || return 1
  [[ $c =~ ^[0-9a-fA-F:]{2,39}/([0-9]{1,3})$ ]] || return 1
  (( BASH_REMATCH[1] <= 128 ))
}

# _fw_in_list <needle> <item>... — is needle one of the items?
_fw_in_list() {
  local needle=$1 c; shift
  for c in "$@"; do [[ $c == "$needle" ]] && return 0; done
  return 1
}

# tls_needs_inbound_acme <mode> — true if the app's cert depends on Let's
# Encrypt reaching the box over 80/443 (the HTTP-01 challenge). The default
# (empty) mode does. `manual` (bring-your-own cert) uses no ACME at all, and
# `dns:*` (DNS-01) proves the challenge over the DNS API — both keep working
# behind a Cloudflare-only firewall, so neither should be warned about.
tls_needs_inbound_acme() {
  case ${1:-} in
    manual|dns:*) return 1 ;;
    *)            return 0 ;;
  esac
}

cmd_firewall_set() { # CIDR ranges on stdin, one per line; # comments allowed
  local line cidrs=()
  while IFS= read -r line; do
    line=${line%%#*}; line=${line//[[:space:]]/}
    [[ -n $line ]] || continue
    valid_cidr "$line" || die "firewall: invalid CIDR '$line'"
    _fw_in_list "$line" ${cidrs[@]+"${cidrs[@]}"} && continue
    cidrs+=("$line")
    [[ ${#cidrs[@]} -le 200 ]] || die "firewall: too many ranges (max 200)"
  done < <(head -c 65536)
  [[ ${#cidrs[@]} -ge 1 ]] || die "firewall: no CIDR ranges on stdin (one per line; use firewall-clear to open up)"
  # zero-gap swap: add the new allows FIRST (ufw skips duplicates), only then
  # remove the broad rules and any previously-saved ranges not in the new set.
  local c
  for c in "${cidrs[@]}"; do
    ufw allow from "$c" to any port 80,443 proto tcp >/dev/null || die "firewall: ufw rejected '$c'"
  done
  ufw delete allow 80/tcp >/dev/null 2>&1 || true
  ufw delete allow 443/tcp >/dev/null 2>&1 || true
  if [[ -f $FIREWALL_WEB_FILE ]]; then
    while IFS= read -r c; do
      [[ -n $c ]] || continue
      _fw_in_list "$c" "${cidrs[@]}" && continue
      ufw delete allow from "$c" to any port 80,443 proto tcp >/dev/null 2>&1 || true
    done < "$FIREWALL_WEB_FILE"
  fi
  printf '%s\n' "${cidrs[@]}" > "$FIREWALL_WEB_FILE"
  echo "firewall: 80/443 restricted to ${#cidrs[@]} range(s) — SSH untouched"
  # ACME can no longer reach the box: warn about every public app whose cert
  # depends on the HTTP-01 challenge, or its issuance/renewal will silently
  # fail. manual (BYO) and dns:* (DNS-01) apps are unaffected — don't warn.
  local cfg dom mode acme=()
  for cfg in "$HOMEPORT_ETC"/*/config; do
    [[ -f $cfg ]] || continue
    dom=$(sed -n 's/^DOMAIN=//p' "$cfg"); [[ -n $dom ]] || continue
    mode=$(sed -n 's/^TLS_MODE=//p' "$cfg")
    if tls_needs_inbound_acme "$mode"; then acme+=("$(basename "$(dirname "$cfg")") ($dom)"); fi
  done
  if [[ ${#acme[@]} -gt 0 ]]; then
    { echo "WARNING: these apps use automatic HTTPS — Let's Encrypt can no longer reach this box to issue or renew their certs:"
      printf '  %s\n' "${acme[@]}"
      echo "  pair the firewall with 'tls: manual' (bring-your-own cert) or a DNS-01 Caddy plugin"
    } >&2
  fi
}

cmd_firewall_clear() {
  local c
  # restore the broad rules first, then drop the per-range ones — zero gap
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  if [[ -f $FIREWALL_WEB_FILE ]]; then
    while IFS= read -r c; do
      [[ -n $c ]] || continue
      ufw delete allow from "$c" to any port 80,443 proto tcp >/dev/null 2>&1 || true
    done < "$FIREWALL_WEB_FILE"
  fi
  rm -f "$FIREWALL_WEB_FILE"
  echo "firewall: 80/443 open to the world again (bootstrap default)"
}

cmd_firewall_list() {
  if [[ -f $FIREWALL_WEB_FILE ]]; then
    echo "80/443 restricted to:"
    sed 's/^/  /' "$FIREWALL_WEB_FILE"
  else
    echo "80/443 open to the world (bootstrap default)"
  fi
}

# ---------------------------------------------------------------------------
# Caddy environment — secrets Caddy itself needs (DNS-provider tokens for
# DNS-01 certs). Values arrive on stdin (never argv), live root-owned 0600 in
# $CADDY_ENV_FILE, and reach Caddy via a systemd EnvironmentFile drop-in
# (systemd reads it as root before dropping privileges). Names only are ever
# printed — same discipline as app secrets.
# ---------------------------------------------------------------------------
valid_env_name() { [[ ${1:-} =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || die "invalid env var name '${1:-}' (A-Z, digits, _)"; }

_caddy_env_dropin() { # ensure caddy.service loads $CADDY_ENV_FILE
  local d=/etc/systemd/system/caddy.service.d
  [[ -f $d/homeport-env.conf ]] && return 0
  mkdir -p "$d"
  printf '[Service]\nEnvironmentFile=-%s\n' "$CADDY_ENV_FILE" > "$d/homeport-env.conf"
  systemctl daemon-reload
}

# _caddy_env_commit <old-content> <had-file> <done-msg> — shared transactional
# tail for env set/rm: validate the Caddyfile under the NEW env before touching
# the service, restart, and restore the old env (+ restart) if anything fails —
# a bad token must never leave Caddy down or poisoned.
_caddy_env_commit() {
  local old=$1 had=$2 msg=$3
  chown root:root "$CADDY_ENV_FILE"; chmod 600 "$CADDY_ENV_FILE"
  _caddy_env_dropin
  _caddy_env_revert() {
    if [[ $had == 1 ]]; then printf '%s' "$old" > "$CADDY_ENV_FILE"
    else rm -f "$CADDY_ENV_FILE"; fi
  }
  if ! caddy_validate; then
    _caddy_env_revert
    die "caddy-env: the Caddyfile does not validate with this change (a dns-provider app may need the token) — reverted, caddy untouched"
  fi
  systemctl restart caddy
  sleep 1
  if ! systemctl is-active --quiet caddy; then
    _caddy_env_revert
    systemctl restart caddy
    die "caddy-env: caddy failed to restart with this change — reverted (check 'journalctl -u caddy')"
  fi
  echo "$msg"
}

cmd_caddy_env_set() { # <NAME>, value on stdin (single line)
  local name=${1:-} val old="" had=0
  valid_env_name "$name"
  val=$(head -c 4096)
  val=${val%$'\n'}
  [[ -n $val ]] || die "caddy-env: empty value on stdin"
  [[ $val != *$'\n'* ]] || die "caddy-env: value must be a single line"
  [[ $val =~ ^[[:print:]]+$ ]] || die "caddy-env: value has non-printable characters"
  [[ -f $CADDY_ENV_FILE ]] && { old=$(cat "$CADDY_ENV_FILE"); had=1; }
  ( umask 077
    touch "$CADDY_ENV_FILE"
    if grep -q "^$name=" "$CADDY_ENV_FILE"; then
      # `|| true`: grep -v exits 1 when the file held ONLY this var (empty
      # result is a valid outcome, not an error — set -e would abort silently)
      grep -v "^$name=" "$CADDY_ENV_FILE" > "$CADDY_ENV_FILE.tmp" || true
      mv "$CADDY_ENV_FILE.tmp" "$CADDY_ENV_FILE"
    fi
    printf '%s=%s\n' "$name" "$val" >> "$CADDY_ENV_FILE"
  )
  _caddy_env_commit "$old" "$had" "caddy-env: $name set (caddy restarted)"
}

cmd_caddy_env_rm() {
  local name=${1:-} old="" had=0
  valid_env_name "$name"
  [[ -f $CADDY_ENV_FILE ]] && grep -q "^$name=" "$CADDY_ENV_FILE" || die "caddy-env: '$name' is not set"
  old=$(cat "$CADDY_ENV_FILE"); had=1
  grep -v "^$name=" "$CADDY_ENV_FILE" > "$CADDY_ENV_FILE.tmp" || true
  mv "$CADDY_ENV_FILE.tmp" "$CADDY_ENV_FILE"
  _caddy_env_commit "$old" "$had" "caddy-env: $name removed (caddy restarted)"
}

cmd_caddy_logs() { # [-n N] — the caddy service journal (deploy can't read it directly)
  local n=80
  [[ ${1:-} == -n && -n ${2:-} ]] && { [[ $2 =~ ^[0-9]{1,4}$ ]] || die "caddy-logs: -n takes a number"; n=$2; }
  journalctl -u caddy -n "$n" --no-pager -o short-iso 2>/dev/null || true
}

cmd_caddy_env_list() {
  if [[ -s $CADDY_ENV_FILE ]]; then
    cut -d= -f1 "$CADDY_ENV_FILE"
  else
    echo "(no caddy env vars set)"
  fi
}

# ---------------------------------------------------------------------------
# Caddy global options — a homeport-managed `{ … }` block for server-wide
# features: a default DNS provider (DNS-01 + ECH publication) and ECH. The block
# lives in its own fragment, 00-globals.caddy, which sorts before every site fragment
# so it lands first in the assembled config — the main Caddyfile is never
# rewritten, so hand edits there stay safe. State (root-written only, safe to
# source) is regenerated into the fragment on every change, transactionally.
# ---------------------------------------------------------------------------
CADDY_GLOBALS_STATE=/etc/homeport/caddy-globals
CADDY_GLOBALS_FRAG=$CADDY_DIR/00-globals.caddy

load_globals() {
  GDNS_PROVIDER="" GDNS_ENV="" GECH=""
  # shellcheck disable=SC1090
  [[ -f $CADDY_GLOBALS_STATE ]] && source "$CADDY_GLOBALS_STATE"
  return 0
}

save_globals() {
  cat > "$CADDY_GLOBALS_STATE" <<EOF
GDNS_PROVIDER=$GDNS_PROVIDER
GDNS_ENV=$GDNS_ENV
GECH=$GECH
EOF
}

# CADDY_ADMIN — where Caddy's admin API listens. Never TCP: on loopback it is
# reachable by every local user and every app, and it can replace the whole
# config. A unix socket inside caddy's 0750 home is caddy + root only;
# `systemctl reload caddy` (ExecReload runs as caddy) reads it from the config.
CADDY_ADMIN_SOCK=/var/lib/caddy/admin.sock
# Where a box that predates the socket still listens (Caddy's default).
CADDY_LEGACY_ADMIN=localhost:2019

# write_caddy_globals — regenerate the global-options fragment from the G*
# vars. Always written: the admin line is not optional.
write_caddy_globals() {
  { printf '# managed by homeport — edit via `homeport server dns|ech`\n'
    printf '{\n'
    printf '\tadmin unix/%s|0600\n' "$CADDY_ADMIN_SOCK"
    if [[ -n $GDNS_PROVIDER ]]; then
      if [[ $GDNS_ENV == none ]]; then
        printf '\tdns %s\n' "$GDNS_PROVIDER"
      else
        printf '\tdns %s {env.%s}\n' "$GDNS_PROVIDER" "$GDNS_ENV"
      fi
    fi
    [[ -n $GECH ]] && printf '\tech %s\n' "$GECH"
    printf '}\n'
  } > "$CADDY_GLOBALS_FRAG"
}

# ensure_caddy_admin_socket — one-time move of a running Caddy's admin API off
# TCP. `caddy reload` dials the address in the NEW config, which the running
# Caddy isn't listening on yet, so this one reload goes to the old address.
# Never dies: a box that can't migrate keeps working as before, and says so.
ensure_caddy_admin_socket() {
  [[ -d $CADDY_DIR ]] || return 0
  grep -qs "admin unix/$CADDY_ADMIN_SOCK" "$CADDY_GLOBALS_FRAG" && return 0
  local had=0 old=""
  [[ -f $CADDY_GLOBALS_FRAG ]] && { old=$(cat "$CADDY_GLOBALS_FRAG"); had=1; }
  load_globals
  write_caddy_globals
  if caddy_validate && caddy reload --config "$CADDYFILE" --adapter caddyfile \
       --address "$CADDY_LEGACY_ADMIN" --force >/dev/null 2>&1; then
    return 0
  fi
  if [[ $had == 1 ]]; then printf '%s\n' "$old" > "$CADDY_GLOBALS_FRAG"; else rm -f "$CADDY_GLOBALS_FRAG"; fi
  echo "warning: could not move Caddy's admin API to $CADDY_ADMIN_SOCK — it is still on TCP loopback" >&2
  return 0
}

# _globals_commit — shared transactional tail: regenerate, validate under the
# caddy env, roll back state + fragment on failure, reload on success.
_globals_commit() {
  local done_msg=$1 oldstate="" hadstate=0 oldfrag="" hadfrag=0
  [[ -f $CADDY_GLOBALS_STATE.prev ]] && { oldstate=$(cat "$CADDY_GLOBALS_STATE.prev"); hadstate=1; }
  [[ -f $CADDY_GLOBALS_FRAG.prev ]] && { oldfrag=$(cat "$CADDY_GLOBALS_FRAG.prev"); hadfrag=1; }
  save_globals
  write_caddy_globals
  if ! caddy_validate; then
    if [[ $hadstate == 1 ]]; then printf '%s' "$oldstate" > "$CADDY_GLOBALS_STATE"; else rm -f "$CADDY_GLOBALS_STATE"; fi
    if [[ $hadfrag == 1 ]]; then printf '%s' "$oldfrag" > "$CADDY_GLOBALS_FRAG"; else rm -f "$CADDY_GLOBALS_FRAG"; fi
    rm -f "$CADDY_GLOBALS_STATE.prev" "$CADDY_GLOBALS_FRAG.prev"
    die "global options failed Caddy validation — rolled back (is the plugin installed and the token set?)"
  fi
  rm -f "$CADDY_GLOBALS_STATE.prev" "$CADDY_GLOBALS_FRAG.prev"
  systemctl reload caddy
  echo "$done_msg"
}

# _globals_snapshot — call before mutating G* vars so _globals_commit can revert.
_globals_snapshot() {
  [[ -f $CADDY_GLOBALS_STATE ]] && cp "$CADDY_GLOBALS_STATE" "$CADDY_GLOBALS_STATE.prev" || rm -f "$CADDY_GLOBALS_STATE.prev"
  [[ -f $CADDY_GLOBALS_FRAG ]] && cp "$CADDY_GLOBALS_FRAG" "$CADDY_GLOBALS_FRAG.prev" || rm -f "$CADDY_GLOBALS_FRAG.prev"
  return 0
}

cmd_global_dns() { # <provider|-> [env-name] — set/clear the global DNS module
  local provider=${1:-} envname=${2:-}
  load_globals
  if [[ $provider == - || -z $provider ]]; then
    [[ -z $GECH ]] || die "ech depends on the global DNS provider — turn it off first"
    _globals_snapshot
    GDNS_PROVIDER="" GDNS_ENV=""
    _globals_commit "caddy: global DNS provider cleared"
    return
  fi
  [[ $provider =~ ^[a-z0-9-]{1,40}$ ]] || die "invalid dns provider '$provider'"
  caddy_has_module "dns.providers.$provider" \
    || die "caddy has no '$provider' DNS module — install it first: homeport server plugins add github.com/caddy-dns/$provider"
  [[ -n $envname ]] || envname=$(dns_default_env "$provider")
  [[ $envname == none || $envname =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || die "invalid env var name '$envname'"
  if [[ $envname != none ]] && ! grep -qs "^$envname=" "$CADDY_ENV_FILE"; then
    die "env var '$envname' is not set for caddy — run 'homeport server caddy-env $envname' first (validation would fail without it)"
  fi
  _globals_snapshot
  GDNS_PROVIDER=$provider GDNS_ENV=$envname
  _globals_commit "caddy: global DNS provider set to $provider"
}

cmd_global_ech() { # <public-name|-> — Encrypted Client Hello
  local name=${1:-}
  load_globals
  if [[ $name == - || -z $name ]]; then
    _globals_snapshot
    GECH=""
    _globals_commit "caddy: ECH off"
    return
  fi
  valid_domain "$name"
  [[ -n $GDNS_PROVIDER ]] || die "ECH needs the global DNS provider to publish its configs — run 'homeport server dns <provider>' first"
  # ech landed in caddy 2.10
  local ver
  ver=$(caddy version 2>/dev/null | awk '{print $1}' | tr -d v)
  [[ $(printf '%s\n2.10.0\n' "$ver" | sort -V | head -1) == "2.10.0" ]] \
    || die "ECH needs caddy >= 2.10 (this box runs $ver)"
  _globals_snapshot
  GECH=$name
  _globals_commit "caddy: ECH on — public name $name (keys generate + publish to DNS automatically)"
}

# cmd_global_ech_rotate — regenerate ECH keys and re-publish HTTPS records.
# Caddy publishes an ECH config ONCE per key generation and caches that it did;
# it won't retroactively publish for a host whose DNS record appeared after ECH
# was first enabled. Clearing the ech keystore forces new keys → Caddy
# re-publishes for every served host that now has a record. Also the standard
# way to rotate ECH keys. (The deploy user can't reach caddy's storage itself —
# only homeportd, as root, can.)
cmd_global_ech_rotate() {
  load_globals
  [[ -n $GECH ]] || die "ECH is not enabled — nothing to rotate (turn it on with 'homeport server ech <name>')"
  local d found=0
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    rm -rf "$d"; found=1
  done < <(find /var/lib/caddy -type d -name ech -path '*caddy*' 2>/dev/null)
  [[ $found == 1 ]] || echo "note: no existing ECH keystore found — fresh keys will be generated" >&2
  systemctl restart caddy
  sleep 2
  systemctl is-active --quiet caddy || die "caddy failed to restart after ECH rotate — check 'homeport server caddy-logs'"
  echo "caddy: ECH keys rotated — new configs publish to DNS for every host that has a record"
}

cmd_global_list() {
  load_globals
  echo "dns provider: ${GDNS_PROVIDER:-(unset)}${GDNS_PROVIDER:+ (env: $GDNS_ENV)}"
  echo "ech:          ${GECH:-off}"
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
      emit_origin_auth $'\t\t'
      emit_reverse_proxy $'\t\t' "$mode" "$ups"
      printf '\t}\n'
    done
    printf '\thandle {\n'
    emit_origin_auth $'\t\t'
    printf '\t\trespond "no route for this path" 404\n\t}\n'
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
  local app=${1:-} domain=${2:-} health=${3:-/} memory=${4:-} cpu=${5:-} idle=${6:-} idle_timeout=${7:-} replicas=${8:-} autoscale=${9:-} run_b64=${10:-} release_b64=${11:-} post_release_b64=${12:-} path=${13:-} sandbox=${14:-} strategy=${15:-} health_timeout=${16:-} static=${17:-} spa=${18:-} headers_b64=${19:-} tls_mode=${20:-} tls_dns_env=${21:-} redirect_from=${22:-} aliases=${23:-} egress=${24:-}
  valid_app "$app"
  die_if_paused "$app"
  # "-" means unset (positional placeholder from the CLI)
  [[ $domain == - ]] && domain=""
  [[ $path == - ]] && path=""
  [[ $headers_b64 == - ]] && headers_b64=""
  [[ $tls_mode == - ]] && tls_mode=""
  [[ $tls_dns_env == - ]] && tls_dns_env=""
  [[ $redirect_from == - ]] && redirect_from=""
  [[ $aliases == - ]] && aliases=""
  validate_headers "$headers_b64"
  validate_tls_mode "$app" "$tls_mode" "$tls_dns_env"
  validate_extra_hosts "$app" "$domain" "$redirect_from" "redirect_from"
  validate_extra_hosts "$app" "$domain" "$aliases" "aliases"
  # static sites are a wholly different shape (Caddy file_server, no process) —
  # handle them in their own function, leaving the binary-app path below untouched.
  [[ $static == 1 ]] && { cmd_add_static "$app" "$domain" "$spa" "$headers_b64" "$tls_mode" "$tls_dns_env" "$redirect_from" "$aliases"; return; }
  [[ $sandbox == - ]] && sandbox=""
  [[ $strategy == - ]] && strategy=""
  [[ $health_timeout == - ]] && health_timeout=""
  [[ -z $health_timeout || $health_timeout =~ ^[0-9]+[smh]$ ]] || die "health timeout must be a number with s/m/h suffix (e.g. 30s, 2m)"
  validate_sandbox "$sandbox" "$release_b64" "$post_release_b64"
  validate_egress "$sandbox" "$egress"
  [[ $egress == - ]] && egress=""
  [[ $sandbox != gvisor ]] || { sandbox_check_tools; ensure_meter_timer; ensure_tenant_slice; }
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
    local _aowner
    _aowner=$(host_alias_owner "$domain" "$app")
    [[ -z $_aowner ]] || die "domain $domain is already an alias of app '$_aowner'"
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
  local SANDBOX=$sandbox EGRESS=$egress STRATEGY=$strategy HEADERS_B64=$headers_b64 TLS_MODE=$tls_mode TLS_DNS_ENV=$tls_dns_env REDIRECT_FROM=$redirect_from ALIASES=$aliases
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
EGRESS=$egress
STRATEGY=$strategy
HEALTH_TIMEOUT=$health_timeout
HEADERS_B64=$headers_b64
TLS_MODE=$tls_mode
TLS_DNS_ENV=$tls_dns_env
REDIRECT_FROM=$redirect_from
ALIASES=$aliases
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
      caddy_upstreams+=" $(app_addr "$p"):$p"
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
ExecStart=/usr/lib/systemd/systemd-socket-proxyd --exit-idle-time=$idle_timeout $(app_addr "$internal_port"):$internal_port
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
  # snapshot every fragment this add may touch, so a validation failure can
  # roll them ALL back — a broken fragment left on disk would fail the NEXT
  # caddy restart, whatever triggers it.
  local _snap_paths=() _snap_data=() _snap_had=() _p
  for _p in "$CADDY_DIR/$app.caddy" \
            ${domain:+"$CADDY_DIR/_gw_$(gateway_slug "$domain").caddy"} \
            ${old_domain:+"$CADDY_DIR/_gw_$(gateway_slug "$old_domain").caddy"}; do
    _snap_paths+=("$_p")
    if [[ -f $_p ]]; then _snap_had+=(1); _snap_data+=("$(cat "$_p")"); else _snap_had+=(0); _snap_data+=(""); fi
  done
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
    if ! caddy_validate; then
      local _i
      for _i in "${!_snap_paths[@]}"; do
        if [[ ${_snap_had[$_i]} == 1 ]]; then printf '%s' "${_snap_data[$_i]}" > "${_snap_paths[$_i]}"
        else rm -f "${_snap_paths[$_i]}"; fi
      done
      die "generated Caddy config failed validation — rolled back"
    fi
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
  # two lines: in one `local`, "homeport-$app" would expand before app is set
  local app=$1 cmd=$2 with_port=${3:-}
  local user="homeport-$app"
  env_normalize "$app"   # bash must read the same values systemd does
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
# gate_decision <scope> <orig> — the policy shared by every forced command that
# re-executes a client's request: a scoped CI key (ci-gate) and a hosted deploy
# certificate (cert-gate). Pure: echoes "allow <off>" (argv index where the
# homeportd verb starts) or "deny <reason>"; no exec/die, so it is unit-tested.
# One allow-list for both, so a verb cannot be open through one door and shut
# through the other.
#
# <scope> is an app name (ci-gate: that app only) or "*" (cert-gate: any app on
# this box — a certificate is scoped to a box, which is one user's). Box scope
# still requires a well-formed app name: verbs build paths from it.
#
# Word-splitting is safe: every token the CLI and the orchestrator send is
# whitespace-free (charset-safe ids/domains, base64 run/release, secrets travel
# via stdin).
gate_decision() {
  local scope=$1 orig=$2
  [[ -n $orig ]] || { echo "deny interactive access is not permitted"; return; }
  local -a a; read -ra a <<<"$orig"
  local off
  if [[ ${a[0]:-} == sudo && ${a[1]:-} == /usr/local/bin/homeportd ]]; then off=2
  elif [[ ${a[0]:-} == /usr/local/bin/homeportd ]]; then off=1
  else echo "deny may only run homeportd (got '${a[0]:-}')"; return; fi
  local verb=${a[off]:-} arg1=${a[off+1]:-}
  case $verb in
    upload|upload-static|add|activate|rollback|env|env-sync|env-rm|env-list|status|logs)
      if [[ $scope == "*" ]]; then
        [[ $arg1 =~ ^[a-z][a-z0-9-]{0,19}$ ]] || { echo "deny invalid app name '${arg1:-(none)}'"; return; }
      else
        [[ $arg1 == "$scope" ]] || { echo "deny scoped to '$scope', not '${arg1:-(none)}'"; return; }
      fi ;;
    version) : ;;
    *) echo "deny verb '${verb:-(none)}' is not permitted"; return ;;
  esac
  echo "allow $off"
}

# ci_gate_decision <app> <orig> — a scoped CI key: one app.
ci_gate_decision() { gate_decision "$1" "$2"; }

# cert_gate_decision <app> <orig> — a hosted deploy certificate: ONE app. The
# CA builds the scope into the certificate's forced command, so it can't be
# widened by the client. There is no box-wide form: on a shared host the box
# holds other customers' apps.
cert_gate_decision() {
  [[ ${1:-} =~ ^[a-z][a-z0-9-]{0,19}$ ]] || { echo "deny this certificate is not scoped to an app"; return; }
  # The control plane retires an app (its owner deleted it) by removing it
  # from the host: allowed for the certificate's OWN app, in exactly the
  # confirmed form. Not in gate_decision, which CI keys share — a CI key
  # never removes, pauses or resumes anything.
  local -a a; read -ra a <<<"${2:-}"
  local off=-1
  if [[ ${a[0]:-} == sudo && ${a[1]:-} == /usr/local/bin/homeportd ]]; then off=2
  elif [[ ${a[0]:-} == /usr/local/bin/homeportd ]]; then off=1; fi
  if (( off >= 0 )) && [[ ${a[off]:-} == remove ]]; then
    if [[ ${a[off+1]:-} == "$1" && ${a[off+2]:-} == --yes && ${#a[@]} -eq $(( off + 3 )) ]]; then
      echo "allow $off"
    else
      echo "deny may only remove '$1', as: remove $1 --yes"
    fi
    return
  fi
  # …and pauses or resumes it (the abuse response), again its own app only
  if (( off >= 0 )) && [[ ${a[off]:-} == pause || ${a[off]:-} == resume ]]; then
    if [[ ${a[off+1]:-} == "$1" && ${#a[@]} -eq $(( off + 2 )) ]]; then
      echo "allow $off"
    else
      echo "deny may only ${a[off]} '$1'"
    fi
    return
  fi
  gate_decision "$1" "${2:-}"
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

# cmd_cert_gate <app> <request> — the SSH forced command for a hosted deploy
# certificate, set by the homeport CA's template: `sudo
# /usr/local/bin/homeportd cert-gate <app> "$SSH_ORIGINAL_COMMAND"`. sshd runs
# it instead of whatever the client asked for; the request arrives as an
# argument because sudo's env_reset drops the env var. The principal confines
# the certificate to this box, the app to one app on it: never another app,
# never remove/self-update/key-add or a shell.
cmd_cert_gate() {
  local app=${1:-} d
  local orig=${2:-}
  [[ $# -ge 2 ]] || die "this certificate is not scoped to an app — refused"
  d=$(cert_gate_decision "$app" "$orig")
  if [[ $d == allow\ * ]]; then
    local off=${d#allow }; local -a a; read -ra a <<<"$orig"
    exec /usr/local/bin/homeportd "${a[@]:off}"
  fi
  die "this certificate may not do that — ${d#deny }"
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
  die_if_paused "$app"
  load_app "$app"
  [[ ${STATIC:-} == 1 ]] && { cmd_activate_static "$app" "$release"; return; }
  local dir="$HOMEPORT_ROOT/$app/releases/$release"
  [[ -f "$dir/bin" ]] || die "no binary at $dir/bin — upload it first"
  chown -R root:root "$dir"
  chmod 755 "$dir/bin"

  # an env file from before canonical storage: fix it before the app (re)starts
  env_normalize "$app"
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
  valid_app "$app"; die_if_paused "$app"; load_app "$app"
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

# --- env file values -------------------------------------------------------------
# The env file is read by systemd (EnvironmentFile=, for the app) and by bash
# (deploy hooks source it). Stored raw, the two disagreed with each other and
# with what was pushed: systemd drops an unquoted backslash; bash splits on
# spaces and expands $(…). So values are decoded ONCE with .env rules and
# stored canonically — KEY="…" escaping only \ " ` $ — which systemd's
# double-quote parser and bash's double quotes both read back byte-for-byte.

# env_decode_value <raw> — the value a raw .env value means. Unquoted:
# literal (backslashes kept — the fix), surrounding whitespace trimmed as
# systemd did. "…": systemd's rules (\" \\ \` \$ unescape, other \x kept).
# '…': literal. Anything else (a quote mid-value, unterminated) is literal.
env_decode_value() {
  local v=$1 inner out="" i c n
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  if [[ ${#v} -ge 2 && ${v:0:1} == '"' && ${v: -1} == '"' ]]; then
    inner=${v:1:${#v}-2}
    for (( i = 0; i < ${#inner}; i++ )); do
      c=${inner:i:1}
      if [[ $c == '\' && $(( i + 1 )) -lt ${#inner} ]]; then
        n=${inner:i+1:1}
        case $n in
          '"'|'\'|'`'|'$') out+=$n; i=$(( i + 1 )) ;;
          *) out+='\' ;;
        esac
      elif [[ $c == '"' ]]; then
        printf '%s' "$v"; return   # an unescaped quote inside: not one quoted value
      else
        out+=$c
      fi
    done
    printf '%s' "$out"; return
  fi
  if [[ ${#v} -ge 2 && ${v:0:1} == "'" && ${v: -1} == "'" && ${v:1:${#v}-2} != *"'"* ]]; then
    printf '%s' "${v:1:${#v}-2}"; return
  fi
  printf '%s' "$v"
}

# env_encode_value <value> — the canonical stored form, quotes included.
env_encode_value() {
  local v=$1
  v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\`/\\\`}; v=${v//\$/\\\$}
  printf '"%s"' "$v"
}

# env_is_canonical <line> — KEY="…" with only \ " ` $ escaped
env_is_canonical() {
  [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*=\"([^\"\\\`\$]|\\[\\\"\`\$])*\"$ ]]
}

# env_render_file <file> [stdin-lines] — print the canonical file: every
# KEY=value line decoded and re-encoded, last value per key wins, first-seen
# order, comments and blanks dropped.
env_render_file() {
  local file=$1 line key
  local -A vals=(); local -a order=()
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key=${line%%=*}
    [[ -n ${vals[$key]+x} ]] || order+=("$key")
    vals[$key]=$(env_decode_value "${line#*=}")
  done < "$file"
  for key in "${order[@]}"; do printf '%s=%s\n' "$key" "$(env_encode_value "${vals[$key]}")"; done
}

# env_install <app> <rendered-file> — put a canonical file in place (root:app 640)
env_install() {
  install -o root -g "homeport-$1" -m 640 "$2" "$HOMEPORT_ROOT/$1/shared/env"
}

# env_normalize <app> — rewrite a legacy (raw) env file canonically. Values
# keep what was pushed; only an unquoted backslash changes meaning (it now
# survives). Cheap no-op when the file is already canonical.
env_normalize() {
  local app=$1 file="$HOMEPORT_ROOT/$1/shared/env" line tmp
  [[ -s $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line ]] && continue
    env_is_canonical "$line" || { tmp=$(mktemp); env_render_file "$file" > "$tmp"; env_install "$app" "$tmp"; rm -f "$tmp"; return 0; }
  done < "$file"
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
      vars[$key]=$(env_decode_value "${line#*=}")
    done < "$file"
  fi
  local added=0
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "invalid env line (expected KEY=value): '${line%%=*}'"
    key=${line%%=*}
    [[ -n ${vars[$key]+x} ]] || order+=("$key")
    vars[$key]=$(env_decode_value "${line#*=}")
    added=$((added + 1))
  done
  (( added > 0 )) || die "no KEY=value lines on stdin"
  local tmp
  tmp=$(mktemp)
  for key in "${order[@]}"; do
    printf '%s=%s\n' "$key" "$(env_encode_value "${vars[$key]}")" >> "$tmp"
  done
  env_install "$app" "$tmp"
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
    newvars[$key]=$(env_decode_value "${line#*=}")
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
  for key in "${order[@]}"; do printf '%s=%s\n' "$key" "$(env_encode_value "${newvars[$key]}")" >> "$tmp"; done
  env_install "$app" "$tmp"; rm -f "$tmp"
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
  env_normalize "$app"
  local tmp removed=0; tmp=$(mktemp)
  while IFS= read -r line; do
    if [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && [[ -n ${drop[${line%%=*}]+x} ]]; then
      removed=$((removed + 1))
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  env_install "$app" "$tmp"; rm -f "$tmp"
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
      local _v; _v=$(env_decode_value "${line#*=}")
      printf '%s{"key":"%s","chars":%d}' "$sep" "$key" "${#_v}"
      sep=","
    done < "$file"
    printf ']\n'
    return
  fi
  [[ -s $file ]] || { echo "(no env set)"; return; }
  while IFS= read -r line; do
    [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key=${line%%=*}
    local _v; _v=$(env_decode_value "${line#*=}")
    printf '%s (%d chars)\n' "$key" "${#_v}"
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
  app_paused && echo "PAUSED:   stopped and not waking — resume to bring it back"
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
  local hdr
  hdr=$(head -5 "$tmp")
  if ! grep -q '^# homeportd ' <<< "$hdr"; then
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
  # a unit that ended failed stays listed (and keeps its state) until reset
  systemctl reset-failed "homeport-$app.service" "homeport-$app@*.service" "homeport-$app-green.service" 2>/dev/null || true
  systemctl reload caddy 2>/dev/null || true
  # the BYO cert dir holds a private key — it must not outlive the app
  rm -rf "${HOMEPORT_ROOT:?}/${app:?}" "${HOMEPORT_ETC:?}/${app:?}" "${TLS_CERT_DIR:?}/${app:?}"
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
  tls-set <app>                      install a bring-your-own cert+key from stdin (tls: manual)
  tls-clear <app>                    remove the manual cert, revert to automatic HTTPS
  caddy-plugin-add <module>...       swap in an official Caddy build with these plugins
  caddy-plugin-rm <module>           drop a plugin (no plugins left = stock apt binary)
  caddy-plugin-list                  show the plugins baked into the running Caddy
  firewall-set                       restrict 80/443 to CIDR ranges from stdin (SSH untouched)
  firewall-clear                     reopen 80/443 to the world (bootstrap default)
  firewall-list                      show the current web-ingress policy
  caddy-env-set <NAME>               set an env var for Caddy from stdin (DNS tokens for tls: dns:*)
  caddy-env-rm <NAME>                remove a Caddy env var
  caddy-env-list                     list Caddy env var names (values never printed)
  caddy-logs [-n N]                  the caddy service journal (TLS/ECH/publication errors)
  global-dns <provider|->            set/clear the global DNS module (DNS-01 default + ECH publication)
  global-ech <public-name|->         Encrypted Client Hello (caddy >= 2.10, needs global-dns)
  global-ech-rotate                  rotate ECH keys & re-publish (fixes late-added records)
  global-list                        show the managed global options
  pause <app>                        stop an app and keep it from waking (nothing deleted)
  resume <app>                       bring a paused app back as it was
  sandbox-install                    install gVisor (runsc) for apps with sandbox: gvisor
  sandbox-run|stop|clean <app> <port> (used by the app's systemd unit)
  meter-tick                         record a minute of usage (run by homeport-meter.timer)
  meter-read <after-seq>             spooled usage records (control plane, via meter-gate)
  meter-ack <seq>                    drop records the control plane has stored
  origin-auth-set [--keep-previous]  require X-Origin-Auth (secret on stdin) on every public site
  origin-auth-retire                 end a rotation: drop the previous value
  origin-auth-clear                  stop requiring it
  origin-auth-status                 on/off (never prints the secret)
  self-update                        replace homeportd with a validated script from stdin
  version [--json]                   homeportd version and API level
  remove <app> --yes                 delete app, releases, env, user
EOF
}

main() {
  [[ $(id -u) -eq 0 ]] || die "must run as root (the homeport CLI calls this via sudo)"
  ensure_origin_auth_snippet
  ensure_caddy_admin_socket
  local cmd=${1:-}
  shift || true
  case $cmd in
    add)      cmd_add "$@" ;;
    upload)   cmd_upload "$@" ;;
    upload-static) cmd_upload_static "$@" ;;
    ci-gate)  cmd_ci_gate "$@" ;;
    cert-gate) cmd_cert_gate "$@" ;;
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
    tls-set)  cmd_tls_set "$@" ;;
    tls-clear) cmd_tls_clear "$@" ;;
    caddy-plugin-add)  cmd_caddy_plugin_add "$@" ;;
    caddy-plugin-rm)   cmd_caddy_plugin_rm "$@" ;;
    caddy-plugin-list) cmd_caddy_plugin_list "$@" ;;
    firewall-set)   cmd_firewall_set "$@" ;;
    firewall-clear) cmd_firewall_clear "$@" ;;
    firewall-list)  cmd_firewall_list "$@" ;;
    caddy-env-set)  cmd_caddy_env_set "$@" ;;
    caddy-env-rm)   cmd_caddy_env_rm "$@" ;;
    caddy-env-list) cmd_caddy_env_list "$@" ;;
    caddy-logs)     cmd_caddy_logs "$@" ;;
    global-dns)     cmd_global_dns "$@" ;;
    global-ech)     cmd_global_ech "$@" ;;
    global-ech-rotate) cmd_global_ech_rotate "$@" ;;
    global-list)    cmd_global_list "$@" ;;
    sandbox-run)   cmd_sandbox_run "$@" ;;
    sandbox-stop)  cmd_sandbox_stop "$@" ;;
    sandbox-clean) cmd_sandbox_clean "$@" ;;
    sandbox-install) cmd_sandbox_install "$@" ;;
    pause)       cmd_pause "$@" ;;
    resume)      cmd_resume "$@" ;;
    meter-tick)  cmd_meter_tick "$@" ;;
    meter-read)  cmd_meter_read "$@" ;;
    meter-ack)   cmd_meter_ack "$@" ;;
    meter-gate)  cmd_meter_gate "$@" ;;
    origin-auth-set)    cmd_origin_auth_set "$@" ;;
    origin-auth-clear)  cmd_origin_auth_clear "$@" ;;
    origin-auth-retire) cmd_origin_auth_retire "$@" ;;
    origin-auth-status) cmd_origin_auth_status "$@" ;;
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
  # homeportd's first run moves Caddy's admin API off TCP loopback (and writes
  # the origin-auth snippet) — do it now rather than on the first deploy.
  /usr/local/bin/homeportd version >/dev/null

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
