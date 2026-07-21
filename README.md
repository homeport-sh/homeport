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

## Install

**macOS / Linux (Homebrew):**
```
brew install homeport-sh/tap/homeport
```

**Linux / macOS (script):**
```
curl -fsSL https://homeport.sh/install | sh
```

Or grab a prebuilt binary for your OS/arch from the
[releases page](https://github.com/homeport-sh/homeport/releases). `homeport`
runs on your laptop/CI — the server needs nothing installed but SSH.

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
   homeport init            # writes homeport.yaml (auto-detects Go, Rust, Next, Nuxt, SvelteKit, TanStack Start, Bun)
   homeport deploy
   ```

## Commands

| Command | What it does |
|---|---|
| `homeport bootstrap root@<ip>` | harden a fresh Ubuntu VPS, install Caddy + homeportd |
| `homeport init` | write `homeport.yaml`, auto-detecting the project type |
| `homeport deploy [--no-build]` | build → upload → activate with health check; auto-reverts on failure |
| `homeport rollback [release]` | instant rollback (old binaries are kept on the box) |
| `ssh deploy@<ip> sudo homeportd remove <app> --yes` | delete an app, its releases, env, and user |
| `homeport secrets set K=V ...` | set env values — sent over ssh stdin, never argv |
| `homeport secrets rm KEY ...` | remove keys from the app's env |
| `homeport secrets push [file\|-]` | merge a whole `.env` file (or stdin) into the env |
| `homeport secrets sync [file\|-]` | declarative full replace — drops keys not in the input |
| `homeport secrets list [--json]` | list env keys; values never leave the server |
| `homeport status [--json]` | state, live release, available releases |
| `homeport apps [server] [--json]` | fleet view: every app on a server (no project dir needed) |
| `homeport stats` | live resource usage — app memory/cpu/tasks, releases disk, host headroom |
| `homeport logs [-f] [-n N]` | app logs (journald) |
| `homeport tunnel [localPort]` | forward a local port to the app (private access / internal apps) |
| `homeport ci setup github` | dedicated CI deploy key + pinned host key + Actions workflow |
| `homeport mcp` | serve these commands as MCP tools (stdio) for AI agents |
| `homeport server update` | push this CLI's bundled homeportd to the box (post-hardening update path) |

**Trust model note:** a full-access deploy key can run any homeportd command
(including `server update`, which replaces the root-side helper) — so it's an
admin credential for its box; treat it like a root key. **CI keys are different:**
`homeport ci setup` issues a key **scoped to one app** via an SSH forced command
— it can deploy and manage that app and *nothing else* (no `remove`, no
`self-update`, no other app, no shell). A leaked CI key can't take the box.
(This is stricter than Kamal or Coolify, which require root SSH / a root daemon.)

## Your binary's contract

- Listen on `$PORT`, bind `$HOST` (`127.0.0.1`) — Caddy terminates TLS in front.
- Persist only under `$STATE_DIR` (the app runs with a read-only filesystem
  view otherwise; `NBC_RUNTIME_DIR` is set to a writable dir for
  next-bun-compile apps).
- A deploy is promoted only after `health.path` returns 200; otherwise the
  previous release is restored automatically. The wait defaults to 30s — raise
  it for slow-booting apps with `health.timeout: 60s` (accepts `s`/`m`/`h`).

## `homeport.yaml` reference

Every field, in one place. `homeport init` writes a commented starter; this is
the full set. Fields marked † expand `${VAR}` from the environment at load time
(a referenced-but-unset var is a hard error).

| Field | Default | What it does |
|---|---|---|
| `app` † | — | app name (lowercase, digits, dashes, ≤20 chars) |
| `server` † | — | `deploy@host` (a bare host defaults the user to `deploy@`) |
| `domain` † | — | public hostname(s) — a string, comma list, or YAML list; the **first is canonical**, the rest serve the same app (a cert each). Omit for internal |
| `redirect_from` | — | domains that **301** to the canonical domain (www → apex, old brand domains); certs + redirects live with the app |
| `internal` | `false` | private app — loopback only, reached via `homeport tunnel` |
| `path` † | — | mount under a shared `domain` (API gateway); prefix is stripped |
| `static` | — | serve a directory of files via Caddy (no process); see [Static sites](#static-sites-no-binary) |
| `spa` | *(auto)* | `true`/`false` override the SPA catch-all fallback for `static` |
| `build.command` | `bun run build`¹ | build step run locally/in CI |
| `build.artifact` | `server` | path to the Linux binary the build produces |
| `health.path` | `/` | must return 200 before a release is promoted |
| `health.timeout` | `30s` | how long to wait for that 200 |
| `run` | — | launch args appended to the binary; `$PORT`/`$HOST` substituted |
| `release` | — | pre-activate hook (migrations) — fails the deploy if it fails |
| `post_release` | — | post-activate hook (best-effort; warns, never reverts) |
| `resources.memory` † | — | cgroup cap, e.g. `512M`, `1G` |
| `resources.cpu` † | — | cgroup cap, e.g. `150%` (= 1.5 cores) |
| `idle` | `false` | scale-to-zero (socket-activated); with `idle_timeout` † (`5m`) |
| `replicas` | `1` | fixed instance count (1–20), load-balanced + rolling |
| `autoscale.{min,max,target_cpu}` | — | dynamic replicas by CPU (`target_cpu` default 70) |
| `sandbox` | `strict` | `relaxed` for binaries that run their own sandbox (browsers) |
| `strategy` | `blue-green` | `recreate` for singletons that can't run two instances |
| `tls` | `auto` | `manual` (cert via `homeport tls set`) or `dns:<provider>` (DNS-01 via a caddy-dns plugin) — see [Bring your own cert](#bring-your-own-cert) |
| `dns_token_env` † | `HOMEPORT_DNS_<PROVIDER>` | env var holding the DNS token for `tls: dns:*`; `none` for SDK-env providers |
| `cloudflare` | `false` | shorthand for `tls: dns:cloudflare` (DNS-01 certs that survive the CF proxy); pair with `homeport server cloudflare` |
| `headers` | — | opt-in response headers (a `Name: value` map) — homeport sets none on its own; see [Response headers](#response-headers) |

¹ `build.command`/`build.artifact` default only for binary apps; a `static` site has no build step by default.

Secrets are **not** in this file — they go through `homeport secrets` and live
only on the server. `idle`, `replicas`, and `autoscale` are mutually exclusive
axes — see the scale-to-zero, replicas, and autoscaling sections below for how
each behaves.

## Response headers

homeport never sets response headers on your behalf — no security or cache
headers are forced onto your app. If you want them, opt in with a `headers:`
map, keyed by **path glob** then header name, emitted verbatim on the app's site
(static or proxied). `"/*"` applies to every response; any other glob scopes the
headers to matching paths:

```yaml
headers:
  "/*": # every response
    Strict-Transport-Security: "max-age=31536000; includeSubDomains"
    X-Frame-Options: SAMEORIGIN
    X-Content-Type-Options: nosniff
  "/_app/immutable/*": # content-hashed assets — safe to cache forever
    Cache-Control: "public, max-age=31536000, immutable"
```

Path-scoping is what lets you long-cache fingerprinted assets *without* caching
your HTML (so deploys still show up immediately). Globs, names and values are
validated against injection into the generated Caddy config: a name is a plain
token, a value is one line without `"`, `\`, `{`, or `}`.

## Multiple domains & www redirects

`domain:` takes one or more hostnames — the first is canonical, the rest serve
the same app (Caddy issues a cert per hostname). `redirect_from:` lists domains
that 301 to the canonical one instead of serving:

```yaml
domain: example.com                 # or: [example.com, example.net]
redirect_from: [www.example.com]    # www → apex, path preserved
```

Use `redirect_from` for www/canonical variants (serving identical content on
two hostnames splits your search ranking); use multiple `domain:` entries only
when the app genuinely lives on several domains. Both lists are owned by the
app — certs and redirects are created with it and removed with it, and no
other app on the box can claim those hostnames.

## Bring your own cert

By default Caddy provisions a Let's Encrypt cert automatically. That can't work
when something in front of your box **terminates TLS** — most commonly a
Cloudflare proxy (orange-cloud). For that case, serve a cert you provide instead:

```yaml
tls: manual   # serve an uploaded cert, don't provision one via ACME
```

Then upload the cert + key (they travel over ssh **stdin**, never argv — the
private key is treated like a secret):

```sh
homeport tls set fullchain.pem privkey.pem   # e.g. a Cloudflare Origin Certificate
homeport tls clear                           # revert to automatic HTTPS
```

homeport never installs a cert on its own — this is entirely opt-in. Pair it
with Cloudflare's SSL/TLS mode set to **Full (strict)**. (`tls: manual` needs a
public domain — it's not for internal or path-mounted apps.)

### DNS-01 certificates (any provider)

Instead of a hand-managed cert, let Caddy issue **real, auto-renewing Let's
Encrypt certs via DNS-01** — it proves ownership by writing a TXT record
through your DNS provider's API, so it works behind a TLS-terminating proxy.
Generic across every [caddy-dns](https://github.com/caddy-dns) provider:

```sh
homeport server plugins add github.com/caddy-dns/cloudflare   # 1. the provider plugin
homeport server caddy-env HOMEPORT_DNS_CLOUDFLARE             # 2. API token (via stdin)
```

```yaml
tls: dns:cloudflare        # 3. per app — or dns:digitalocean, dns:route53, …
```

The token env var defaults to `HOMEPORT_DNS_<PROVIDER>`; set `dns_token_env:`
to use a different name, or `dns_token_env: none` for providers that read
standard SDK env vars (e.g. route53 with `AWS_ACCESS_KEY_ID` — set those via
`caddy-env` too). Tokens travel over ssh stdin, live root-owned on the box,
and reach Caddy through a systemd `EnvironmentFile` — never argv, never git.
Use a token scoped to DNS-edit on the one zone.

### Behind Cloudflare, in one command

Cloudflare is common enough to get a shortcut. `server cloudflare` does the
three server-side steps above at once — installs the plugin, stores the token
(prompted, hidden), and sets Cloudflare as the global DNS provider:

```sh
homeport server cloudflare        # paste a Zone → DNS → Edit token, press Enter
```

Then each app opts in with one line — pure shorthand for `tls: dns:cloudflare`,
setting nothing else on your behalf:

```yaml
cloudflare: true
```

Certs now issue and renew over the DNS API, straight through the orange-cloud
proxy. Optionally lock the origin so attackers can't bypass the edge:

```sh
homeport server firewall allow cloudflare
```

## DNS records (no per-app management)

The simplest way to skip DNS management entirely is a **wildcard**: point
`*.example.com` at the box once and every app you deploy on a subdomain is
instantly resolvable — nothing else to do, ever. A wildcard `A` record never
overrides an explicit record, so any host you point elsewhere (or proxy) still
wins; the wildcard just catches everything else.

For a custom root domain or a stricter setup with no wildcard, add that one
record by hand. It's a one-time step per domain, and it's the honest place to
draw the line: homeport deliberately does **not** auto-create or auto-update
your DNS records. Record automation (e.g. `caddy-dynamicdns`) exists to chase a
*changing* IP — on a static-IP VPS it's a no-op — and it can only write
**DNS-only (grey)** records, with no way to mark a record proxied. So on any
zone that mixes proxied and direct hosts it can't create the record you
actually want, and homeport has no authoritative way to tell which hosts are
proxied (that state lives at your DNS provider, not in `homeport.yaml`). The
wildcard covers the common case with zero moving parts; a hand-added record
covers the rest.

## Encrypted Client Hello (ECH)

[ECH](https://caddyserver.com/docs/caddyfile/options) stops TLS from leaking
which site a visitor is opening (the SNI is encrypted). Caddy ≥ 2.10 generates
the keys and **publishes them as HTTPS-type DNS records** — which is why ECH
needs the same DNS-provider setup as DNS-01 certs above: the provider plugin,
the `caddy-env` **DNS-edit token** (publication writes records through it),
and the global provider. The whole chain:

```sh
homeport server plugins add github.com/caddy-dns/cloudflare
homeport server caddy-env HOMEPORT_DNS_CLOUDFLARE   # zone-scoped DNS-edit token
homeport server dns cloudflare
homeport server ech ech.example.com    # a "public name" you control — the decoy SNI
homeport server ech off
```

(Each step refuses to run with an actionable error if the previous one is
missing, so you can't half-configure it — and a token that the global config
references can't be removed out from under it either.)

One thing validation **can't** catch for `ech`: a
wrong-but-well-formed token. Caddy checks the token's shape at load, not its
validity — homeport won't call your DNS provider's API to probe it. After
enabling, confirm the records actually appeared in your DNS dashboard, and
check `homeport logs`-style on the box with `journalctl -u caddy` for provider
errors if they didn't.

Browsers only use ECH when DNS-over-HTTPS is enabled, so treat it as
defense-in-depth. It shines on a box hosting many domains — outside observers
see only the public name, not which of your sites was visited.

## Caddy plugins

Caddy's ecosystem (DNS providers, rate limiting, geo-IP, …) ships as compile-time
plugins. homeport installs them **without a Go toolchain on the box**: it
downloads a build with your plugins baked in from **Caddy's official build
service** (the same one behind caddyserver.com's download page), verifies it
(runs, contains the module, current Caddyfile validates), swaps it in, and rolls
back automatically if Caddy doesn't come back healthy.

```sh
homeport server plugins add github.com/caddy-dns/cloudflare   # install
homeport server plugins                                       # list
homeport server plugins rm github.com/caddy-dns/cloudflare    # remove
```

The apt-installed binary is preserved via `dpkg-divert` — removing the last
plugin restores stock Caddy and its apt security-upgrade path. While a custom
build is active it is **not** upgraded by apt; re-run a `plugins add` to refresh
it. Plugin *configuration* (e.g. wiring a DNS provider into cert issuance) is
separate — this command manages what's compiled in.

## Web-ingress firewall

Running behind an edge proxy only helps if attackers can't skip it: your origin
IP is usually in public DNS history, so the real protection is a kernel-level
firewall that only accepts web traffic **from the edge's IP ranges**:

```sh
homeport server firewall allow cloudflare  # fetch CF's live ranges → 80/443 only from Cloudflare
homeport server firewall                    # show the current policy
homeport server firewall clear              # reopen to the world
```

`allow cloudflare` pulls Cloudflare's [current edge ranges](https://www.cloudflare.com/ips/)
(v4 + v6) and applies them — no list to paste or keep up to date. For any other
edge (or a custom allow-list), pass a file or `-` for stdin instead; it's a
declarative CIDR list (one per line, `#` comments) that replaces the previous
policy wholesale:

```sh
curl -s https://api.fastly.com/public-ip-list | jq -r '.addresses[]' > edge.txt
homeport server firewall allow edge.txt
```

Rules are swapped with no gap, enforced by the kernel (dropped before a TCP
handshake — no per-request checks anywhere), and **SSH is never touched**, so a
bad policy can only break web traffic, not lock you out. Once the box only
accepts edge traffic, Let's Encrypt can't reach it over HTTP-01 — so pair the
firewall with `tls: manual` (BYO cert) or `tls: dns:<provider>` (DNS-01, which
proves the challenge over the DNS API). homeport warns you about any app still
on plain automatic HTTPS, and leaves `manual`/`dns:` apps alone.

## Static sites (no binary)

A folder of files — an SPA, a docs site, a landing page — needs no process at
all: point `static:` at the built directory and Caddy serves it directly (auto
HTTPS, compression, ETags), so there's *nothing* running on the box but the
file server.

```yaml
# homeport.yaml
app: docs
domain: docs.example.com
static: ./dist          # the built directory
build:
  command: npm run build   # optional — omit for plain HTML
# spa: true             # optional override; auto-detected by default
```

`homeport deploy` builds (if `build.command` is set), tars the directory,
streams it up, and flips an atomic symlink — the new files are live instantly,
**zero downtime, no reload**. Rollback is a flip.

**SPA vs multi-page is auto-detected**, so client-routed apps get the right
catch-all fallback and static-per-route sites don't:

| Your build | Detected | Behaviour |
|---|---|---|
| SvelteKit `adapter-static` (SPA) → `200.html` | **SPA** | unmatched routes serve the app shell |
| Vite / CRA → lone `index.html` | **SPA** | ″ |
| Next `output: export`, Astro, Hugo, Docusaurus → per-route `.html` | **multi-page** | clean URLs (`/about` → `about.html`); unmatched → 404 |

Set `spa: true`/`false` to override. Static apps are public (a domain, no
`internal`) and have no process — so `run`, `idle`, `replicas`, `autoscale`,
`sandbox`, `resources` don't apply. If your app needs SSR / API routes /
server functions, it's not static — deploy it as a **binary** (see the
framework notes below), which is what `*-bun-compile` produces.

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
(default) is a plain single service, activated **blue/green** (next section).
Autoscaling (below) also works for internal apps.

## Zero-downtime activation (blue/green)

A single-instance **public** app deploys **blue/green by default** — no config
needed. On `homeport deploy` the new release starts on a private port while the
old one keeps serving; once the new one passes its health check, Caddy flips to
it, the old instance is retired, and traffic never drops. If the new release is
unhealthy the flip never happens — the old one keeps serving and the deploy
reverts, so a bad build is invisible to users (verified: 0/400 requests dropped
across a live flip).

This means two instances of the app **coexist for a few seconds** during each
deploy. That's fine for stateless web apps, but a **singleton** — one that holds
an exclusive lock, or is a single scheduler that must never double-run — can't
tolerate it. Opt such an app out:

```yaml
strategy: recreate   # restart in place instead (brief downtime, never 2 at once)
```

Scope: blue/green is the default for single-instance **public** apps. Multi
-instance apps (`replicas`/autoscale) already deploy **rolling** and zero
-downtime; **internal** and **path-mounted** single-instance apps restart in
place (give them `replicas: 2` for zero-downtime); **idle** apps use socket
activation. `strategy: recreate` forces in-place restart anywhere it would
otherwise be blue/green.

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
│  homeport (CLI) │─── ssh / scp ─────▶│ homeportd — one root-side bash helper│
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

Generates a dedicated ed25519 deploy key **scoped to this app** (an SSH forced
command lets it deploy/manage only `app` — never remove it, self-update
homeportd, touch another app, or open a shell), authorizes it on the server,
pins the server's host key (no `StrictHostKeyChecking=no`), writes
`.github/workflows/homeport-deploy.yml` with the right toolchain step for your
project type, and sets the SSH-key + host-key repo secrets via `gh` if
available. Pass `--unscoped` for a full-access key (an admin credential for the
box) if one pipeline must manage several apps.

**Revoking a key** (leaked, or a retired pipeline) — from any admin session:

```
ssh deploy@<ip> sudo homeportd key-list            # fingerprints + scope
ssh deploy@<ip> sudo homeportd key-rm homeport-ci-web   # by comment or fingerprint
```

Revocation is immediate (the next SSH auth fails), and `key-rm` refuses to
remove the last remaining key so you can't lock yourself out.

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
| `status` · `apps` · `stats` · `logs` | observe the app and the fleet |
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

- Multi-server fan-out (`servers:` list) for the same app.

A web dashboard is intentionally **not** on the near-term roadmap: for a
single box the CLI plus `homeport mcp` (agent-driven ops) cover it, and a
tunnel-only local UI would add friction over the CLI it wraps. A dashboard
returns only as a future multi-server cloud control plane.

## Support

If homeport saves you time, you can [buy me a coffee](https://buymeacoffee.com/ramonmalcolm) ☕

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/ramonmalcolm)
