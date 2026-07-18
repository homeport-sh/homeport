# homeport

Deploy single-binary web apps — Go, Rust, `bun --compile`, anything that
ships as one executable — to your own VPS. No Docker, no registry, no agent,
no runtime installed on the server. One command hardens a fresh box; one
command deploys.

```
homeport bootstrap root@1.2.3.4    # once per server
homeport init                      # once per project
homeport secrets push .env         # if you have secrets
homeport deploy                    # build → upload → health-checked activate
```

A €4/mo Hetzner box comfortably hosts a dozen apps this way.

## Why binaries

The artifact you tested is byte-for-byte the artifact that runs. Deploys are
a file copy + symlink flip: atomic, instantly rollback-able, and the server
needs nothing installed — no Node, no Bun, no Go, no `apt install` drift.

## Quick start (never touched a VPS before?)

1. **Create a server** — e.g. Hetzner Cloud → Add Server → Ubuntu 24.04,
   the cheapest shared box is fine. Add your SSH key when prompted. Copy
   the server's IP.
2. **Bootstrap it** (from your laptop):
   ```
   homeport bootstrap root@<ip>
   ```
   This hardens the box (firewall, key-only SSH, no root login, fail2ban,
   auto security updates), installs Caddy (automatic HTTPS), and installs
   `homeportd`, the server-side helper. Idempotent — safe to re-run.
   Alternatively, paste `bootstrap/bootstrap.sh` into Hetzner's *user data*
   field at creation and the box sets itself up on first boot.
3. **Point DNS** — an A record for your domain to the server IP. TLS
   certificates are issued automatically once it resolves.
   *No domain handy?* Use `<app>.<your-ip-with-dashes>.sslip.io` as the
   domain (e.g. `web.203-0-113-9.sslip.io` for `203.0.113.9`) — [sslip.io](https://sslip.io)
   resolves it to your IP with zero DNS setup, and Caddy still gets a real
   Let's Encrypt cert. Great for a first try; use your own domain for
   production (sslip.io is a shared public resolver).
4. **In your project**:
   ```
   homeport init            # writes homeport.yaml (auto-detects Go / Rust / next-bun-compile)
   homeport deploy
   ```

## Commands

| Command | What it does |
|---|---|
| `homeport bootstrap root@<ip>` | harden a fresh Ubuntu VPS, install Caddy + homeportd |
| `homeport init` | write `homeport.yaml`, auto-detecting the project type |
| `homeport deploy [--no-build]` | build → upload → activate with health check; auto-reverts on failure |
| `homeport rollback [release]` | instant rollback (old binaries are kept on the box) |
| `homeport secrets set K=V ...` | set env values — sent over ssh stdin, never argv |
| `homeport secrets push [file]` | upload a whole `.env` file |
| `homeport secrets list` | list env keys; values never leave the server |
| `homeport status [--json]` | state, live release, available releases |
| `homeport apps [server] [--json]` | fleet view: every app on a server (no project dir needed) |
| `homeport stats` | live resource usage — app memory/cpu/tasks, releases disk, host headroom |
| `homeport logs [-f] [-n N]` | app logs (journald) |
| `homeport tunnel [localPort]` | forward a local port to the app (private access / internal apps) |
| `homeport ci setup github` | dedicated CI deploy key + pinned host key + Actions workflow |
| `homeport mcp` | serve these commands as MCP tools (stdio) for AI agents |
| `homeport server update` | push this CLI's bundled homeportd to the box (post-hardening update path) |

**Trust model note:** `server update` means a deploy key can replace the
root-side helper — so a deploy key is an admin credential for its box.
Treat deploy keys like root keys; scoped per-app CI keys are on the
roadmap. (This is still stricter than Kamal or Coolify, which require root
SSH / a root daemon outright.)

## Your binary's contract

- Listen on `$PORT`, bind `$HOST` (`127.0.0.1`) — Caddy terminates TLS in front.
- Persist only under `$STATE_DIR` (the app runs with a read-only filesystem
  view otherwise; `NBC_RUNTIME_DIR` is set to a writable dir for
  next-bun-compile apps).
- A deploy is promoted only after `health.path` returns 200; otherwise the
  previous release is restored automatically.

## Private apps (no public URL)

```yaml
# homeport.yaml — omit `domain:` and set:
internal: true
```

An internal app binds to `127.0.0.1` with **no Caddy fragment and nothing on
80/443**. Reach it two ways:

- **from other apps on the box** — `http://127.0.0.1:<port>` (service-to-service)
- **from your laptop** — `homeport tunnel` forwards a local port over SSH:

```
homeport tunnel            # → http://localhost:<port>  (Ctrl-C to close)
homeport tunnel 8080       # pick the local port
```

`homeport tunnel` works for public apps too, when you want private access
without going through the internet.

## Many apps, one domain: path routing (optional)

Put several apps behind a **single hostname**, each mounted at a path prefix —
an API gateway, one cert, one DNS record:

```yaml
# geo-api/homeport.yaml
domain: api.example.com
path: /geo-api

# users/homeport.yaml
domain: api.example.com
path: /users
```

```
https://api.example.com/geo-api/*  → the geo-api app
https://api.example.com/users/*    → the users app
```

Each app still gets its own loopback port, systemd unit, secrets, and
health-checked/rolling deploys — **only its routing changes**. homeport merges
every app sharing a domain into one Caddy site block (a `handle_path` per
prefix, longest-first so `/users/admin` wins over `/users`), regenerating it on
each add/remove. TLS for the shared host is issued automatically.

Things to know:

- **The prefix is stripped.** `GET /geo-api/lookup` reaches the app as
  `/lookup` — the app doesn't need to know its mount point. (Health checks run
  against the app's own port, so `health.path` stays app-relative too.)
- **A host is one or the other.** A domain is either a single whole-host app
  *or* a gateway of path-mounted apps — homeport rejects mixing them, and
  rejects two apps claiming the same prefix, with a clear message.
- **Unmatched paths 404** on the shared host.
- Path apps compose with **replicas / autoscale / idle** — each contributes its
  own load-balanced (or scale-to-zero) upstream to the gateway block.

For deeper fan-out (per-path rate limits, auth, header rewrites) you can still
drop a hand-written Caddy fragment in `/etc/caddy/homeport.d/`; `path:` covers
the common "several services under one host" case without touching Caddy.

## Resource limits (optional)

```yaml
# homeport.yaml
resources:
  memory: 512M   # hard cap; throttled at 90%, OOM-killed at 100%
  cpu: 150%      # 150% = 1.5 cores
```

These become systemd cgroup directives (`MemoryMax`/`MemoryHigh`/`CPUQuota`)
— the same kernel mechanism Docker uses for `--memory`/`--cpus`. Omit the
block for no limits. `homeport stats` shows the cap next to live usage.

## Scale to zero (optional)

```yaml
# homeport.yaml
idle: true
idle_timeout: 5m   # default 5m
```

For **low-traffic** apps. systemd holds the app's port and starts the binary
on the first request, then stops it after `idle_timeout` of no traffic —
**zero RAM while asleep**, so a box can hold far more mostly-idle apps.
Implemented with systemd socket activation + `systemd-socket-proxyd`, so it
works for any binary (no runtime support needed).

The first request after idle pays the cold-start (fast for Go, ~1s for a big
JS-framework binary). **Don't** use it on a busy or latency-sensitive app —
it never idles out anyway, and you'd just add a proxy hop. Always-on apps
(the default) are untouched: no socket, no proxy, direct port bind.

## Replicas & rolling deploys (optional)

```yaml
# homeport.yaml
replicas: 3
```

Runs N instances of the app (systemd template units), load-balanced by Caddy
(`least_conn` + passive health checks that pull a dead replica out). Deploys
become **rolling and zero-downtime**: instances restart one at a time,
health-checked, while the others keep serving.

Works for **public and internal apps alike**. A public app is balanced behind
its domain; an **internal** app is balanced on **loopback** — Caddy listens on
`127.0.0.1:<port>` and spreads across the instances, so other apps on the box
keep calling `127.0.0.1:<port>` exactly as before but now get HA + more cores.
(`homeport tunnel` still reaches it, and hits the load balancer.)

Size replicas to the box's cores — on a single VPS, more replicas don't add
capacity the box doesn't have; they mainly help single-process runtimes
(Node/Bun) use more cores. Mutually exclusive with `idle`. `replicas: 1`
(default) is a plain single service, unchanged. Autoscaling (below) also works
for internal apps.

## Autoscaling (optional)

```yaml
# homeport.yaml (public apps)
autoscale:
  min: 1
  max: 4
  target_cpu: 70   # scale up above, down below; default 70
```

A systemd timer samples each replica's CPU every 20s and adjusts the running
count between `min` and `max`, with hysteresis and a 60s cooldown so it can't
flap. **Scales on CPU, not memory** — replicas add CPU capacity (cores), so
CPU is the signal scaling actually relieves; adding replicas would only make
memory pressure worse (each needs its own RAM). Memory is a *limit*
(`resources.memory`), not a trigger.

Most useful for single-process runtimes (Node/Bun — so Next/Nuxt/SvelteKit/
TanStack binaries), which use one core per instance: idle runs `min` replicas
(saving the rest's RAM), load bursts to `max` to use more cores. Ceiling is
the box's cores — true capacity autoscaling (add machines) is multi-server.
Mutually exclusive with `idle` and fixed `replicas`.

## Databases

homeport is **app-tier only** — it deploys your binary; the database lives
elsewhere. That's the model: the box is cattle, state is not on it. You
connect via a **connection string in secrets**, which is the universal
interface to *every* provider:

```bash
homeport secrets set DATABASE_URL="postgres://user:pass@host/db?sslmode=require"
```

That one line works with **Neon, Supabase, PlanetScale, Turso, DigitalOcean
managed DB, RDS — anything** — with no provider-specific setup. homeport
intentionally has **no per-provider integration and no backup feature**:
those balloon into per-vendor / per-engine surface for marginal value, and
backups are better handled by the provider or a purpose-built tool. The
connection-string-as-secret *is* the integration.

**Practical guidance:**

- **Match region.** A Falkenstein app hitting a US database pays ~100 ms per
  query. Put the DB in the same region as the box.
- **Allowlist the box IP** in the provider's firewall / trusted sources, and
  keep `sslmode=require`.
- **On DigitalOcean:** if you use a DO managed DB, run homeport on a DO
  droplet in the same VPC — then the app can reach the DB's **private**
  endpoint (a different cloud can't), low-latency and unexposed.
- **Migrations:** use a [release hook](#release-hooks-migrations) — `release:
  ./bin migrate` runs on the box against the new binary before it goes live,
  and aborts the deploy if it fails.

**Cheapest options:**

- **SQLite in `$STATE_DIR`** — $0, no extra service, genuinely production-fit
  for a single box. Back it up continuously with
  [Litestream](https://litestream.io) to Cloudflare R2 / Backblaze B2
  (pennies). Caveat: single-writer, and the DB is state on the box, so it's
  not for multi-box/HA.
- **A free-tier serverless DB** — Turso (libSQL) or Neon (Postgres) start at
  $0, keep the DB off your box (backups + PITR handled), and scale later.

**Don't** `apt install postgresql` on the app box — that puts a stateful
service next to your binaries (backups, tuning, OOM contention) and breaks
the binaries-only model. If you want self-hosted Postgres, give it its own
box.

## Release hooks (migrations)

A `release:` command runs **on the box, against the new binary, before it goes
live** — the place for database migrations and other one-shot pre-flight work:

```yaml
# homeport.yaml
release: ./bin migrate      # chain steps with &&
```

On each deploy, after the new release is staged but before any instance
restarts onto it, homeport runs the hook:

- as the **app user**, with the app's **secrets in the env** (`DATABASE_URL`,
  …) plus `STATE_DIR` — the same environment the app itself gets;
- in the new release's directory, so `./bin` is the **new** binary;
- **before promotion** — the old release keeps serving until it succeeds.

If the hook exits non-zero the **deploy aborts**: nothing is promoted, the
previous release stays live, and `homeport deploy` returns an error (so CI
fails loudly). This is the [Heroku release-phase](https://devcenter.heroku.com/articles/release-phase)
pattern — engine-agnostic, so it works for a Go `migrate` subcommand, `bunx
drizzle-kit migrate`, `atlas migrate apply`, a `psql -f` script, anything.

The safe ordering for zero-downtime migrations is **expand → migrate →
deploy → contract**: ship a migration the *current* code tolerates, let the
hook apply it, then the new code goes live on top of it. Avoid destructive
changes (dropping a column the running release still reads) in the same deploy
that ships the code removing that read — split it across two.

### After it's live: `post_release`

A `post_release:` command runs **after** the app is promoted and passing its
health check, reachable at `$HOST:$PORT`:

```yaml
release: ./bin migrate          # before promotion — gates the deploy
post_release: ./bin warm-cache  # after it's live — best-effort
```

It's for side effects that need the *new* release actually serving — cache
warming, a smoke test, a CDN purge, a deploy notification. It's **best-effort
by design**: by the time it runs the release is already live and a migration
may have run, so a failure **can't safely auto-revert**. A failed
`post_release` therefore only warns (the deploy still counts as success); if
you need a hard gate, put the check in `release:` or the health endpoint. On a
laptop/no-CI deploy it's the only place to hang after-live work; in CI you can
equally use a step after `homeport deploy` returns.

There's deliberately **no on-failure hook**: a failed deploy already surfaces
itself (non-zero exit in CI, the error in your terminal) and homeport
auto-reverts on a health-check failure. For alerting on a failed deploy, use
CI's `if: failure()` step — don't run arbitrary code on the box in a
known-broken state.

**Not on homeport?** The same idea maps to your platform: on Kubernetes this is
an **init container** (or a pre-deploy `Job`) running `migrate` against the
remote DB before the app pods start — same expand→migrate→contract ordering,
same "gate the rollout on it," just k8s-native. The release hook is homeport's
equivalent for the runtimeless single-binary box.

## How it works

```
your laptop / CI                     the VPS
┌──────────────┐                    ┌──────────────────────────────────┐
│  homeport (CLI) │─── ssh / scp ─────▶│ homeportd — bash, root, ~400 lines  │
└──────────────┘                    │  the only privileged entry point │
                                    │  systemd units · Caddy · releases│
                                    └──────────────────────────────────┘
```

- **`homeportd`** is installed by bootstrap and is the single root-side entry
  point (the `deploy` user's only sudo grant). It validates every input.
- **Releases** live in `/opt/homeport/<app>/releases/<id>/`; `current` is a
  symlink, so activation is atomic and rollback is a flip.
- **systemd** supervises each app with a hardened unit (`ProtectSystem=strict`,
  `NoNewPrivileges`, dedicated non-login user per app, one writable dir).
- **Caddy** routes per-domain and manages TLS; per-app fragments in
  `/etc/caddy/homeport.d/`.
- **Secrets** live on the server (`shared/env`, root-owned, mode 640),
  loaded via systemd `EnvironmentFile` — CI needs no app secrets at all.

## Security & hardening

`homeport bootstrap` and each app's systemd unit apply defense in depth:

**The box** — non-root `deploy` user whose *only* privilege is running
`homeportd` (a single sudo grant); ufw default-deny with just 22/80/443 and
SSH rate-limited; key-only SSH, root login off, `MaxAuthTries` capped;
fail2ban; automatic security upgrades; and kernel `sysctl` hardening
(`ptrace_scope=1` so one app can't read another's memory, restricted
kptr/dmesg, reverse-path filtering, no ICMP redirects / source routing).

**Each app** runs under a tight systemd sandbox: a dedicated non-login user,
`ProtectSystem=strict` with exactly one writable directory, `NoNewPrivileges`,
**all Linux capabilities dropped**, a **seccomp syscall filter**
(`@system-service`), no namespaces, `PrivateDevices`, `ProtectProc=invisible`,
and hardened kernel/clock/hostname protections. So a compromised binary —
including a third-party one — can touch very little.

```yaml
# a binary that runs its OWN sandbox (e.g. a Chromium-based browser) needs the
# aggressive filters relaxed — it uses user namespaces + seccomp itself:
sandbox: relaxed
```

`relaxed` keeps the baseline (strict filesystem, no-new-privileges, dedicated
user) but drops the capability/namespace/syscall restrictions the nested
sandbox needs. We deliberately **don't** set `MemoryDenyWriteExecute` — it
would break JIT runtimes (Bun/Node). Existing boxes pick up the box-level
`sysctl`/SSH changes by re-running `homeport bootstrap` (idempotent); the
per-app sandbox ships with `homeport server update` and applies on next deploy.

## Deploying from CI

```
homeport ci setup github
```

Generates a dedicated ed25519 deploy key, authorizes it on the server, pins
the server's host key (no `StrictHostKeyChecking=no`), writes
`.github/workflows/homeport-deploy.yml` with the right toolchain step for your
project type, and sets the SSH-key + host-key repo secrets via `gh` if
available.

**Secrets — two patterns** (the generated workflow uses B by default):

- **A — managed on the server.** You set them once by hand
  (`homeport secrets push .env`); they persist across deploys and **CI never
  sees them**. Smallest blast radius. Delete the "Sync secrets" step from the
  workflow if you use this.
- **B — managed as CI secrets, synced every deploy.** Your env lives as
  GitHub Actions secrets and the workflow runs `homeport secrets sync -`
  before deploy, so the box's env matches CI exactly (declarative — a secret
  you delete in GitHub is dropped on the box). List **all** your keys and add
  each as a repo secret first. Use `push -` instead of `sync -` for additive
  (never-delete) behaviour.

Either way, secrets sync **before** deploy so the app boots with the right
env, and values travel over SSH stdin — never argv, never logs, never git.

### Per-environment values (`${VAR}` in `homeport.yaml`)

One committed `homeport.yaml` can serve staging and production: the
parameterizable fields — `server`, `domain`, `app`, `path`, `resources`,
`idle_timeout` — expand `${VAR}`/`$VAR` from the environment at load time.

```yaml
# homeport.yaml — committed once
app: web-${ENV}
server: deploy@${DEPLOY_HOST}
domain: ${DOMAIN}
```
```yaml
# workflow — set the env; homeport expands it
- run: homeport deploy
  env:
    ENV: production
    DEPLOY_HOST: ${{ vars.DEPLOY_HOST }}
    DOMAIN: ${{ vars.DOMAIN }}
```

A **referenced-but-unset variable is a hard error** — a missing CI variable
fails the deploy loudly instead of shipping an empty domain. Domain/server are
*config*, not secrets, so put them in GitHub **Variables** (`vars.`) and scope
them per **Environment** (staging/production) — not in `secrets.`. The command
fields (`run`, `release`, `post_release`, `build`) are **not** expanded, so
`run:`'s `$PORT`/`$HOST` keep their homeport meaning.

Because *unset* errors but *set-but-empty* is allowed, `domain: ${DOMAIN}` also
lets you flip an app **public ↔ internal per environment**: an empty `DOMAIN`
makes it internal (loopback, no TLS), a real host makes it public, and a
missing one is a loud error rather than an accidental exposure change.

## Driving deploys from an AI agent (MCP)

`homeport mcp` serves the CLI as a stdio [MCP](https://modelcontextprotocol.io)
server, so an agent (Claude Code, etc.) can operate your fleet — with the same
health-gated, auto-reverting safety you get.

Register it (once, from a project with a `homeport.yaml`):

```
claude mcp add homeport -- homeport mcp
```

Then ask the agent things like *"roll back the api", "show me the logs for
web", "how much memory is the fleet using"*. Exposed tools:

| Tool | |
|---|---|
| `status` · `stats` · `logs` | observe the app |
| `deploy` · `rollback` | ship / revert (health-gated, auto-revert) |
| `secrets_list` · `secrets_set` · `secrets_rm` | manage env |

Setup commands (`bootstrap`, `init`, `ci`) and `secrets sync` (a destructive
full-replace) are deliberately **not** exposed — those stay human-run. The
MCP server operates on the app in its working directory, same as the CLI.

## Deploying a plain Node/Bun app

homeport deploys a **single binary** — that's the whole model (no runtime on
the server, atomic swaps, high density). Go, Rust, and the framework adapters
(Next, Nuxt, SvelteKit, TanStack) already produce one. A plain Node/Bun server
usually can too, with `bun build --compile`:

```yaml
# homeport.yaml
build:
  command: bun build --compile --target=bun-linux-x64 ./src/index.ts --outfile server
  artifact: server
```

```bash
PORT=3000 ./server   # test locally (drop --target to build for your machine)
```

**It doesn't fit every app — be honest with yourself first.** `bun --compile`
bundles your JS into one executable, so it breaks when the app reaches outside
that bundle:

- **native addons** — `better-sqlite3`, `sharp`, `bcrypt`, anything node-gyp —
  don't bundle into the binary
- **dynamic `require()` / plugin systems** — the bundler can't see them
- **reading files by path at runtime** (`__dirname`-relative assets, templates)
  — those aren't embedded

If your app hits one of those, it isn't a good fit for homeport today — a tool
that reliably does one thing (binaries) beats one that half-supports
everything. Pick a managed platform with a Node runtime for that app, or
refactor the offending dependency out.

## Deploying a third-party binary (Lightpanda, MinIO, …)

homeport deploys **any** single static binary — including ones you didn't
compile. Point `build.command` at a download, and use `run:` for the launch
flags (for binaries that take `--host/--port` flags instead of the `$PORT`
env convention). Example — Lightpanda (a lightweight headless browser) as an
internal backend your app talks to over loopback:

```yaml
app: lightpanda
server: deploy@1.2.3.4
internal: true                          # a backend service, not public
run: serve --host $HOST --port $PORT    # $PORT/$HOST substituted at launch
sandbox: relaxed                        # Chromium-based: runs its own sandbox
build:
  command: >
    curl -fsSL https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-x86_64-linux
    -o server && chmod +x server
  artifact: server
health:
  path: /json/version
```

(`sandbox: relaxed` because a Chromium-based browser needs user namespaces +
seccomp for its *own* sandbox, which the default strict profile blocks. A
plain Go/Rust/Bun binary needs no such line — leave it on the strict default.)

`homeport deploy` uploads the binary and systemd runs it as
`server serve --host 127.0.0.1 --port <port>`. Your app connects on
`http://127.0.0.1:<port>` (loopback, private, zero network latency) — a
headless browser for Puppeteer without a Chromium pod, idling at a couple MB
until it's working.

## Apps with external files or native addons

The single-binary model wants **everything in the binary**. Two common cases:

- **A runtime data file** (a GeoIP `.mmdb`, a template pack, …) — embed it
  with Go's `//go:embed` (or your language's equivalent) so it ships inside
  the binary. Download it in `build.command`, embed it at compile time; no
  external file at runtime. This is a strict improvement — one binary instead
  of binary + sidecar data dir.
- **A native addon** — `sharp`, `better-sqlite3`, `bcrypt`, anything with a
  compiled `.node` / libvips / native `.so`. These **don't bundle** into a
  compiled binary. Options, best first: **(1)** offload the work to a managed
  service (image processing → Cloudflare Images / imgix; your app just makes
  URLs); **(2)** swap for a pure-Go/Rust library that compiles in (basic image
  ops → `disintegration/imaging`); **(3)** if you truly need the native lib's
  performance, that specific service isn't a homeport fit — run it elsewhere.
  Don't fight `bun --compile` to embed libvips; it's a losing battle.

It's your box, so you *can* SSH in and `apt install` a runtime or system
library by hand — homeport doesn't stop you. But treat that as a last resort,
not a workflow: the dependency becomes un-captured state homeport neither
manages nor reproduces (rebuild the box and it's gone), and you've traded
away the nothing-installed model that's the whole point. If you find yourself
doing it, the app probably belongs on a different platform.

## Building a release binary

```
go build -trimpath -ldflags="-s -w" -o homeport ./cmd/homeport
```

Cross-compile with `GOOS`/`GOARCH` as usual.

## Roadmap

- Blue/green zero-downtime activation (current strategy is a 1–2s restart).
- Per-app-scoped CI keys via forced commands.
- Configurable health-check timeout (currently a fixed 30s).
- Multi-server fan-out (`servers:` list) for the same app.

A web dashboard is intentionally **not** on the near-term roadmap: for a
single box the CLI plus `homeport mcp` (agent-driven ops) cover it, and a
tunnel-only local UI would add friction over the CLI it wraps. A dashboard
returns only as a future multi-server cloud control plane.
