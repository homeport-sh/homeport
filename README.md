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

## Documentation

**Full documentation lives at [docs.homeport.sh](https://docs.homeport.sh).**

- [Quick start](https://docs.homeport.sh/quick-start) — a bare VPS to a live HTTPS app
- [Configuration](https://docs.homeport.sh/configuration) — every `homeport.yaml` field
- [Commands](https://docs.homeport.sh/reference/commands) — the full CLI surface
- Guides — [behind Cloudflare](https://docs.homeport.sh/guides/deploying-behind-cloudflare),
  [static sites](https://docs.homeport.sh/guides/static-sites),
  [multiple domains](https://docs.homeport.sh/guides/multiple-domains),
  [path routing](https://docs.homeport.sh/guides/path-routing),
  [TLS certificates](https://docs.homeport.sh/guides/tls-certificates),
  [the web firewall](https://docs.homeport.sh/guides/web-firewall),
  [resources & scaling](https://docs.homeport.sh/guides/resources-and-scaling),
  [databases](https://docs.homeport.sh/guides/databases)
- [AI agents (MCP)](https://docs.homeport.sh/reference/mcp) — drive deploys from an assistant

## Why binaries

The artifact you tested is byte-for-byte the artifact that runs. Deploys are
a file copy + symlink flip: atomic, instantly rollback-able, and the server
needs nothing installed — no Node, no Bun, no Go, no `apt install` drift.

## Security

`homeport bootstrap` hardens the box before anything ships: key-only SSH, no
root login, a firewall, fail2ban, and automatic security updates. A
full-access deploy key is an admin credential for its box — treat it like a
root key. **CI keys are different:** `homeport ci setup` issues a key scoped to
one app via an SSH forced command, so it can deploy and manage that app and
*nothing else* — no removal, no self-update, no other app, no shell. A leaked
CI key can't take the box. (Stricter than tools that require root SSH or a root
daemon.)

## Development

Build the CLI from source:

```
go build -trimpath -ldflags="-s -w" -o homeport ./cmd/homeport
```

Cross-compile with `GOOS`/`GOARCH` as usual. `homeportd`, the server-side
helper, is embedded in `bootstrap/bootstrap.sh` and ships inside the binary.

## Roadmap

- Multi-server fan-out (`servers:` list) for the same app.

A web dashboard is intentionally **not** on the near-term roadmap: for a single
box the CLI plus `homeport mcp` (agent-driven ops) cover it. A dashboard returns
only as a future multi-server cloud control plane.

## License

homeport is [Fair Source](https://fair.io): the
[Functional Source License, MIT future license](LICENSE.md) (FSL-1.1-MIT).

- **Use it freely:** self-host it, deploy your own or your company's apps,
  modify it, and use it for education, research, or client work.
- **The one thing you can't do** is offer it as a competing commercial
  service: selling homeport hosting to others.
- **Every release becomes plain MIT two years after it's published.**

Releases up to v0.4.1 were published under MIT and stay MIT.

## Support

If homeport saves you time, you can [buy me a coffee](https://buymeacoffee.com/ramonmalcolm) ☕

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/ramonmalcolm)
