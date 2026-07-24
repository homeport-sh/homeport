# Nuxt → single binary → homeport

A minimal Nuxt app that compiles to one executable and deploys with
[homeport](../../). Nuxt builds through **Nitro**; with the `bun` preset the
server output can be compiled into a single binary by `bun build --compile`.

## The two things that make it work

1. **Three top-level Nitro options** — `nuxt.config.ts`:
   ```ts
   export default defineNuxtConfig({
     nitro: {
       preset: 'bun',              // Bun-compatible server output
       serveStatic: 'inline',      // embed .output/public into the bundle
       inlineDynamicImports: true, // single entry file for bun --compile
     }
   })
   ```
   This makes `nuxt build` emit a Bun-compatible server at
   `.output/server/index.mjs` with the static assets embedded. Without
   `serveStatic: 'inline'` the compiled binary ships without
   `.output/public`, and CSS/JS 500 at runtime.

2. **`homeport.yaml`** — a two-step build (Nitro build, then compile):
   ```yaml
   build:
     command: bun --bun run build && bun build --compile --bytecode --production --minify --sourcemap --target=bun-linux-x64 --outfile dist/app .output/server/index.mjs
     artifact: dist/app
   ```
   `--target=bun-linux-x64` cross-compiles for a standard x86-64 Linux box
   (use `bun-linux-arm64` for ARM, or drop `--target` when building on the
   same architecture as the server, e.g. in CI).

   The binary is `dist/app`, deliberately: Nitro treats a root-level
   `server/` as a convention directory, so naming the artifact `server`
   at the project root shadows it and breaks the next build.

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
bun build --compile --outfile dist/app .output/server/index.mjs   # no --target = native
PORT=3000 ./dist/app
```
