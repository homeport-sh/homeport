# Homeport

**The fastest way to ship binaries to production.**

Deploy single-binary web apps — Go, Rust, `bun --compile`, anything that
ships as one executable — to your own VPS. One command hardens a fresh box
(firewall, key-only SSH, fail2ban, Caddy with automatic HTTPS); one command
deploys with health-checked activation and instant rollback. No Docker, no
registry, no runtime installed on the server.

This package currently reserves the name. The full release will make
`npx homeport` install the platform binary automatically.

- Website: https://homeport.sh
- Source: https://github.com/homeport-sh/homeport
