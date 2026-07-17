package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// projectInfo is what init auto-detects so homeport.yaml starts out correct
// for the toolchain at hand instead of generic.
type projectInfo struct {
	kind      string // "next-bun-compile", "go", "rust", "generic"
	app       string
	build     string
	artifact  string
	note      string // extra comment block for homeport.yaml
	gitignore string // entry to append, "" if none
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
			_, dep := pkg.Dependencies["next-bun-compile"]
			_, dev := pkg.DevDependencies["next-bun-compile"]
			if dep || dev {
				return projectInfo{
					kind:     "next-bun-compile",
					app:      sanitizeAppName(pkg.Name),
					build:    "bun run build",
					artifact: "server",
					note: `# next-bun-compile emits the binary for the machine it builds on.
# Building on macOS? Make the build target Linux, or deploy from CI
# (homeport ci setup github) where the runner is already Linux.`,
					ciToolchain: `      - uses: oven-sh/setup-bun@v2
      - run: bun install --frozen-lockfile`,
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
		server = ask("Server (deploy@your-server-ip)", "")
	}
	domain := flagVal("domain")
	if domain == "" {
		domain = ask("Domain (e.g. app.example.com)", "")
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
domain: %s

build:
%s
  command: %s
  # path to the single Linux executable the build produces
  artifact: %s

health:
  # a deploy is only promoted once this path returns 200 on the new binary
  path: /
`, app, server, domain, indentComment(det.note), det.build, det.artifact)

	if err := os.WriteFile(configFile, []byte(yaml), 0o644); err != nil {
		return err
	}
	step("wrote %s", configFile)

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
