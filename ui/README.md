# homeport ui (planned)

An optional dashboard for a homeport server: app status, logs, env keys,
restart and a rollback button. Not part of the MVP — the CLI is fully
functional without it.

## Design (settled, not yet built)

- **A SvelteKit app compiled to a single binary** (svelte-bun-compile) —
  deployed onto the box *by homeport itself*, so it gets releases, health
  checks and rollback like any other app. The dashboard that manages your
  apps is managed like your apps.
- **Unprivileged.** It runs as its own system user and talks to `homeportd`
  through the same sudo boundary the deploy user has. All privileged
  mutations stay inside homeportd's ~400 audited lines.
- **Localhost-only by default.** It binds 127.0.0.1 and is reached via
  `homeport ui`, which opens an SSH tunnel and the browser. Zero public attack
  surface; exposing it behind Caddy + auth is a deliberate opt-in.
- **Contract:** `homeportd` JSON outputs (`status --json`, `env-list --json`,
  `version --json`) — API level is reported by `homeportd version` and bumped
  on breaking changes. The UI never screen-scrapes text output.
