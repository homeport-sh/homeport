package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// projectInfo is what init auto-detects so homeport.yaml starts out correct
// for the toolchain at hand instead of generic.
type projectInfo struct {
	kind        string // "next-bun-compile", "go", "rust", "generic"
	app         string
	build       string
	artifact    string
	note        string // extra comment block for homeport.yaml
	gitignore   string // entry to append, "" if none
	ciToolchain string // GitHub Actions step(s) installing the build toolchain
}

func detectProject() projectInfo {
	if data, err := os.ReadFile("package.json"); err == nil {
		var pkg struct {
			Name            string            `json:"name"`
			Dependencies    map[string]string `json:"dependencies"`
			DevDependencies map[string]string `json:"devDependencies"`
		}
		if json.Unmarshal(data, &pkg) == nil {
			has := func(name string) bool {
				_, dep := pkg.Dependencies[name]
				_, dev := pkg.DevDependencies[name]
				return dep || dev
			}
			bunCI := `      - uses: oven-sh/setup-bun@v2
      - run: bun install --frozen-lockfile`

			if has("next-bun-compile") {
				return projectInfo{
					kind: "next-bun-compile",
					app:  sanitizeAppName(pkg.Name),
					// NBC_TARGET cross-compiles; default to a standard x86-64
					// Linux box so a macOS build deploys as-is.
					build:    "NBC_TARGET=bun-linux-x64 bun run build",
					artifact: "server",
					note: `# NBC_TARGET cross-compiles the binary: bun-linux-x64 for a standard
# x86-64 Linux box, bun-linux-arm64 for ARM. Drop it to build for the
# current machine (e.g. in CI, which is already Linux).`,
					ciToolchain: bunCI,
				}
			}

			if has("svelte-bun-compile") {
				return projectInfo{
					kind: "svelte-bun-compile",
					app:  sanitizeAppName(pkg.Name),
					// --bun is required: the adapter compiles via Bun.build.
					build:    "bun --bun vite build",
					artifact: "dist/app",
					note: `# svelte-bun-compile builds for the machine it runs on. Deploying
# from macOS to a Linux box? Set the adapter target in svelte.config.js:
#   adapter({ target: 'bun-linux-x64' })   (or bun-linux-arm64 for ARM)
# — or deploy from CI (homeport ci setup github), which is already Linux.`,
					ciToolchain: bunCI,
				}
			}

			// Nuxt and TanStack Start both build through Nitro; with the "bun"
			// preset the server lands at .output/server/index.mjs, which
			// `bun build --compile` turns into one binary. Same recipe for both.
			// --production is load-bearing, not cosmetic: it sets
			// NODE_ENV=production so conditional requires (e.g. Vue's
			// vue.cjs.js) take their self-contained prod path instead of
			// dev branches that reference unbundled deps like @vue/shared.
			nitroBuild := "bun --bun run build && " +
				"bun build --compile --bytecode --production --minify --sourcemap " +
				"--target=bun-linux-x64 --outfile server .output/server/index.mjs"
			nitroNote := func(fw, presetHint string) string {
				return `# ` + fw + ` builds through Nitro. This compiles the Nitro server
# output into one binary, and REQUIRES the Nitro "bun" preset:
#   ` + presetHint + `
# --target=bun-linux-x64 cross-compiles for a standard x86-64 Linux box;
# use bun-linux-arm64 for ARM servers, or drop --target when building on
# the same architecture as the server (e.g. in CI).`
			}

			if has("nuxt") {
				return projectInfo{
					kind:        "nuxt",
					app:         sanitizeAppName(pkg.Name),
					build:       nitroBuild,
					artifact:    "server",
					note:        nitroNote("Nuxt", `nitro: { preset: 'bun' }   // in nuxt.config.ts`),
					ciToolchain: bunCI,
				}
			}

			if has("@tanstack/react-start") || has("@tanstack/solid-start") {
				return projectInfo{
					kind:        "tanstack-start",
					app:         sanitizeAppName(pkg.Name),
					build:       nitroBuild,
					artifact:    "server",
					note:        nitroNote("TanStack Start", `nitro({ preset: 'bun' })   // in vite.config.ts`),
					ciToolchain: bunCI,
				}
			}
		}
	}

	if data, err := os.ReadFile("go.mod"); err == nil {
		name := "app"
		if m := regexp.MustCompile(`(?m)^module\s+(\S+)`).FindStringSubmatch(string(data)); m != nil {
			name = filepath.Base(m[1])
		}
		return projectInfo{
			kind:     "go",
			app:      sanitizeAppName(name),
			build:    "CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o .homeport/app .",
			artifact: ".homeport/app",
			note: `# Cross-compiles for a x86-64 server; use GOARCH=arm64 for ARM boxes
# (e.g. Hetzner CAX).`,
			gitignore: ".homeport/",
			ciToolchain: `      - uses: actions/setup-go@v5
        with:
          go-version: stable`,
		}
	}

	if data, err := os.ReadFile("Cargo.toml"); err == nil {
		name := "app"
		if m := regexp.MustCompile(`(?m)^name\s*=\s*"([^"]+)"`).FindStringSubmatch(string(data)); m != nil {
			name = m[1]
		}
		return projectInfo{
			kind:     "rust",
			app:      sanitizeAppName(name),
			build:    "cargo build --release --target x86_64-unknown-linux-musl",
			artifact: "target/x86_64-unknown-linux-musl/release/" + sanitizeAppName(name),
			note: `# Needs: rustup target add x86_64-unknown-linux-musl
# (use aarch64-unknown-linux-musl for ARM servers).`,
			ciToolchain: `      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: x86_64-unknown-linux-musl`,
		}
	}

	cwd, _ := os.Getwd()
	// A package.json with no framework we compile for = a plain Node/Bun app.
	// homeport needs a single binary — point at `bun build --compile`, but be
	// honest that it doesn't fit every app (native addons, dynamic requires).
	if _, err := os.Stat("package.json"); err == nil {
		return projectInfo{
			kind:     "generic",
			app:      sanitizeAppName(filepath.Base(cwd)),
			build:    "bun build --compile --target=bun-linux-x64 ./src/index.ts --outfile server",
			artifact: "server",
			note: `# Node/Bun app: homeport deploys a single binary, so this compiles your
# server entrypoint with 'bun build --compile'. EDIT the entrypoint path.
# Works for most pure-JS servers (Hono, Express, plain HTTP). If your app
# uses native addons (better-sqlite3, sharp, bcrypt...), dynamic require(),
# or reads files by path at runtime, compilation may need flags or won't
# work — see the "plain Node/Bun app" note in the homeport README.`,
			ciToolchain: `      - uses: oven-sh/setup-bun@v2
      - run: bun install --frozen-lockfile`,
		}
	}
	return projectInfo{
		kind:     "generic",
		app:      sanitizeAppName(filepath.Base(cwd)),
		build:    "make build",
		artifact: "app",
		note: `# TODO: set build.command to whatever produces a single Linux
# executable at build.artifact.`,
	}
}

func sanitizeAppName(name string) string {
	name = strings.ToLower(name)
	if i := strings.LastIndex(name, "/"); i >= 0 {
		name = name[i+1:] // strip npm scope or module path
	}
	name = regexp.MustCompile(`[^a-z0-9-]+`).ReplaceAllString(name, "-")
	name = strings.Trim(name, "-")
	if len(name) > 20 {
		name = name[:20]
	}
	if name == "" || !appRe.MatchString(name) {
		return "app"
	}
	return name
}

func cmdInit(args []string) error {
	if _, err := os.Stat(configFile); err == nil && !hasFlag(args, "--force") {
		return fmt.Errorf("%s already exists (use --force to overwrite)", configFile)
	}
	flagVal := func(name string) string {
		for i, a := range args {
			if a == "--"+name && i+1 < len(args) {
				return args[i+1]
			}
		}
		return ""
	}

	det := detectProject()
	if det.kind != "generic" {
		step("detected %s project", det.kind)
	}

	in := bufio.NewReader(os.Stdin)
	ask := func(label, def string) string {
		if def != "" {
			fmt.Printf("%s [%s]: ", label, def)
		} else {
			fmt.Printf("%s: ", label)
		}
		line, _ := in.ReadString('\n')
		if line = strings.TrimSpace(line); line != "" {
			return line
		}
		return def
	}

	app := flagVal("app")
	if app == "" {
		app = ask("App name", det.app)
	}
	server := flagVal("server")
	if server == "" {
		server = ask("Server IP (or user@host)", lastServer())
	}
	server = normalizeServer(server)
	domain := flagVal("domain")
	if domain == "" {
		// No domain yet? sslip.io resolves <anything>.<ip-with-dashes>.sslip.io
		// to that IP with zero DNS setup, and Caddy still gets real TLS for it.
		host := server[strings.Index(server, "@")+1:]
		hint := "e.g. app.example.com"
		if net.ParseIP(host) != nil {
			hint = fmt.Sprintf("e.g. %s.%s.sslip.io for instant TLS, no DNS", app, strings.ReplaceAll(host, ".", "-"))
		}
		domain = ask("Domain ("+hint+")", "")
	}

	switch {
	case !appRe.MatchString(app):
		return fmt.Errorf("app name must be lowercase letters, digits, dashes, max 20 chars (got %q)", app)
	case !strings.Contains(server, "@"):
		return fmt.Errorf("server should look like deploy@1.2.3.4 (got %q)", server)
	case !domainRe.MatchString(domain):
		return fmt.Errorf("%q doesn't look like a domain", domain)
	}

	yaml := fmt.Sprintf(`# homeport deploy config — safe to commit (secrets go via `+"`homeport secrets`"+`)
app: %s
server: %s
# public app: set a domain (Caddy fronts it with automatic TLS).
# no domain yet? use  <app>.<your-ip-with-dashes>.sslip.io  — it resolves to
# your IP with zero DNS setup and still gets real TLS. Great for trying things;
# get a real domain for production (sslip.io is a shared public resolver).
# private app: remove this line and set  internal: true  — the app binds to
# loopback and is reached with  homeport tunnel , nothing on 80/443.
# tip: server/domain/app/path/resources expand ${VAR} from the environment, so
# one file can serve staging & prod from CI (an unset var is a hard error).
domain: %s

# Optional path mount: put several apps behind ONE domain, each at a prefix
# (an API gateway). Give each app the same domain: and a distinct path:.
# Caddy strips the prefix, so the app sees /users, not /api/users.
# path: /geo-api    # -> https://<domain>/geo-api/* reaches this app

build:
%s
  command: %s
  # path to the single Linux executable the build produces
  artifact: %s

health:
  # a deploy is only promoted once this path returns 200 on the new binary
  path: /
  # how long to wait for that 200 before failing the deploy (default 30s).
  # Raise it for apps that boot slowly (JIT warm-up, cache load).
  # timeout: 60s

# Optional release hook: a command run on the box (as the app user, with your
# secrets in the env) against the NEW binary, BEFORE it goes live. If it fails
# the deploy aborts and the old release keeps serving — the place for DB
# migrations. Chain steps with &&.
# release: ./bin migrate

# Optional post-release hook: runs AFTER the app is live and healthy, at
# $HOST:$PORT. Best-effort (cache warm, smoke test, notify) — a failure warns
# but does NOT roll back, so keep hard gates in release: or the health check.
# post_release: ./bin warm-cache

# Optional sandbox level. Default (strict) locks the app down with a tight
# systemd profile (dropped capabilities, seccomp syscall filter, no namespaces).
# Set 'relaxed' only for a binary that runs its OWN sandbox and needs those
# back — e.g. a Chromium-based browser like Lightpanda.
# sandbox: relaxed

# Deploy strategy for a single-instance PUBLIC app. Default 'blue-green' is
# zero-downtime (new release proven on a private port, then traffic flips).
# Use 'recreate' for a SINGLETON that can't run two instances at once (holds an
# exclusive lock, a singleton scheduler, etc.) — it restarts in place instead.
# strategy: recreate

# Optional cgroup limits (systemd — the same kernel mechanism as docker).
# resources:
#   memory: 512M   # hard cap; throttled at 90%%, OOM-killed at 100%%
#   cpu: 150%%      # 150%% = 1.5 cores

# Optional scale-to-zero for low-traffic apps: systemd holds the port and
# starts the app on the first request, then stops it after idle_timeout.
# Zero RAM while asleep; first request after idle pays the cold-start. Never
# use it on a busy or latency-sensitive app.
# idle: true
# idle_timeout: 5m

# Optional horizontal replicas: N instances load-balanced by Caddy, with
# rolling zero-downtime deploys. Works for public apps AND internal ones
# (an internal service is balanced on loopback; consumers keep using its
# 127.0.0.1:<port>). Sized to the box's cores — more replicas don't add
# capacity a single box doesn't have.
# replicas: 3
`, app, server, domain, indentComment(det.note), det.build, det.artifact)

	if err := os.WriteFile(configFile, []byte(yaml), 0o644); err != nil {
		return err
	}
	step("wrote %s", configFile)
	saveLastServer(server)

	if det.gitignore != "" {
		if err := ensureGitignore(det.gitignore); err == nil {
			step("added %s to .gitignore", det.gitignore)
		}
	}

	fmt.Printf(`
next steps:
  homeport bootstrap root@%s     # once, if the server isn't set up yet
  homeport secrets push .env      # if you have secrets
  homeport deploy
`, server[strings.Index(server, "@")+1:])
	return nil
}

func indentComment(note string) string {
	lines := strings.Split(note, "\n")
	for i, l := range lines {
		lines[i] = "  " + l
	}
	return strings.Join(lines, "\n")
}

func ensureGitignore(entry string) error {
	data, _ := os.ReadFile(".gitignore")
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == entry {
			return nil
		}
	}
	f, err := os.OpenFile(".gitignore", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if len(data) > 0 && !strings.HasSuffix(string(data), "\n") {
		fmt.Fprintln(f)
	}
	_, err = fmt.Fprintln(f, entry)
	return err
}
