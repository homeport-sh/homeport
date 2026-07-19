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
  forced command to **one app**. Within that app it has full control — ship its
  code, apply its config from `homeport.yaml` (including `sandbox`), manage its
  secrets — which is intentional: a key that can deploy a binary already runs
  arbitrary code as that app's user, so its own config is in scope. What it
  **cannot** do is the boundary that matters: reach another app, remove an app,
  `self-update` homeportd, open a shell, or run an arbitrary command on the box.
  A leaked scoped key should be contained to its one app and must not be able to
  take the box — that boundary is the thing most worth reporting a break in.
- Secrets travel over SSH stdin, never argv or a remote shell; app binaries are
  root-owned so the app user can execute but not modify what it runs; each app
  runs in a locked-down systemd sandbox.

## Supported versions

The latest release receives security fixes. Pre-1.0, that is whatever `latest`
points to.
