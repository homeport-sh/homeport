# Nuxt → single binary → homeport

A minimal Nuxt app that compiles to one executable and deploys with
[homeport](../../). Nuxt builds through **Nitro**; with the `bun` preset the
server output can be compiled into a single binary by `bun build --compile`.

## The two things that make it work

1. **Nitro `bun` preset** — `nuxt.config.ts`:
   ```ts
   export default defineNuxtConfig({
     nitro: { preset: 'bun' }
   })
   ```
   This makes `nuxt build` emit a Bun-compatible server at
   `.output/server/index.mjs`.

2. **`homeport.yaml`** — a two-step build (Nitro build, then compile):
   ```yaml
   build:
     command: bun --bun run build && bun build --compile --bytecode --production --minify --sourcemap --target=bun-linux-x64 --outfile server .output/server/index.mjs
     artifact: server
   ```
   `--target=bun-linux-x64` cross-compiles for a standard x86-64 Linux box
   (use `bun-linux-arm64` for ARM, or drop `--target` when building on the
   same architecture as the server, e.g. in CI).

`homeport init` writes all of this automatically — it detects Nuxt from
`package.json`.

## Deploy

```bash
bun install
homeport init                 # detects Nuxt, writes homeport.yaml (already here)
# edit server: and domain: in homeport.yaml for your box
homeport deploy
```

Nitro's server reads `PORT` / `HOST`, which homeport sets (`127.0.0.1` +
an assigned port behind Caddy) — so it satisfies homeport's app contract
with no extra config.

## Run the binary locally

```bash
bun --bun run build
bun build --compile --outfile server .output/server/index.mjs   # no --target = native
PORT=3000 ./server
```
