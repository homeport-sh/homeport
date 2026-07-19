# Security policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.

- Use GitHub's [private vulnerability reporting](https://github.com/homeport-sh/homeport/security/advisories/new), or
- email **security@homeport.sh** with details and, if possible, a proof of concept.

I aim to acknowledge within 72 hours and to ship a fix promptly for anything
that lets a deploy key escalate beyond its documented scope.

## Trust model (what to assume)

- **A full-access deploy key is root-equivalent for its box** — it can run any
  homeportd command, including `server update` (which replaces the root-side
  helper). Treat it like a root key.
- **A scoped CI key** (`homeport ci setup`, the default) is confined by an SSH
  forced command to deploying and managing **one app** — it cannot remove apps,
  self-update homeportd, reach another app, open a shell, or run arbitrary
  commands. A leaked scoped key should not be able to take the box; that
  boundary is the thing most worth reporting a break in.
- Secrets travel over SSH stdin, never argv or a remote shell; app binaries are
  root-owned so the app user can execute but not modify what it runs; each app
  runs in a locked-down systemd sandbox.

## Supported versions

The latest release receives security fixes. Pre-1.0, that is whatever `latest`
points to.
