# Next.js → single binary → homeport

A minimal Next.js app that compiles to one executable and deploys with
[homeport](../../), using the
[next-bun-compile](https://www.npmjs.com/package/next-bun-compile) build
adapter.

## The two things that make it work

1. **The build adapter** — `next.config.ts`:
   ```ts
   const nextConfig: NextConfig = {
     adapterPath: 'next-bun-compile',
   }
   ```
   `next build` then assembles the app and compiles it to a single binary
   named `server` (no `output: 'standalone'`, no `.next` to ship — the
   binary contains everything).

2. **`homeport.yaml`**:
   ```yaml
   build:
     command: NBC_TARGET=bun-linux-x64 bun run build
     artifact: server
   ```

`homeport init` writes this automatically — it detects next-bun-compile from
`package.json`.

## Deploy

```bash
bun install
homeport init                 # detects next-bun-compile, writes homeport.yaml (already here)
# edit server: and domain: in homeport.yaml for your box
homeport deploy
```

## Cross-compiling (macOS → Linux)

next-bun-compile builds the binary for the machine it runs on. Deploying from
an Apple-Silicon Mac to an x86-64 Linux box needs a Linux build — the
simplest path is to **deploy from CI** (`homeport ci setup github`), where the
runner is already Linux. See the next-bun-compile docs for cross-compile
targets if you want to build locally.

## Run the binary locally

```bash
bun run build
PORT=3000 ./server
```
