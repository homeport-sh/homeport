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

## Deploying from CI

```
homeport ci setup github
```

Generates a dedicated ed25519 deploy key, authorizes it on the server, pins
the server's host key (no `StrictHostKeyChecking=no`), writes
`.github/workflows/homeport-deploy.yml` with the right toolchain step for your
project type, and sets the two repo secrets via `gh` if available. The
pipeline's only secrets are the SSH key and host key.

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
