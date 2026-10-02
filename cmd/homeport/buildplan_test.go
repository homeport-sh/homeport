package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// repo writes files into a fresh directory.
func repo(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range files {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func plan(t *testing.T, files map[string]string) buildPlan {
	t.Helper()
	p, err := planBuild(repo(t, files))
	if err != nil {
		t.Fatalf("plan: %v", err)
	}
	return p
}

func TestAGoRepoBuildsAStaticBinaryWithItsGoVersion(t *testing.T) {
	p := plan(t, map[string]string{"go.mod": "module example.com/app\n\ngo 1.24.2\n"})
	if p.Toolchain != "go" || p.Image != "golang:1.24.2" || p.Install != "" || p.Artifact != "server" ||
		!strings.Contains(p.Command, "CGO_ENABLED=0 go build") || !strings.Contains(p.Command, "-o server") {
		t.Fatalf("%+v", p)
	}
	// a toolchain line wins over the go line
	p = plan(t, map[string]string{"go.mod": "module m\n\ngo 1.23\n\ntoolchain go1.24.5\n"})
	if p.Image != "golang:1.24.5" {
		t.Fatalf("toolchain: %+v", p)
	}
}

func TestABunRepoInstallsThenBuilds(t *testing.T) {
	p := plan(t, map[string]string{
		"package.json": `{"name":"app","packageManager":"bun@1.3.2","scripts":{"build":"bun build --compile src/index.ts --outfile server"}}`,
		"bun.lock":     "{}",
	})
	if p.Toolchain != "bun" || p.Image != "oven/bun:1.3.2" || p.Install != "bun install --frozen-lockfile" ||
		p.Command != "bun run build" || p.Artifact != "server" {
		t.Fatalf("%+v", p)
	}
	// .bun-version, and the major alone without either
	if p := plan(t, map[string]string{"package.json": `{}`, "bun.lock": "{}", ".bun-version": "1.2.20\n"}); p.Image != "oven/bun:1.2.20" {
		t.Fatalf(".bun-version: %+v", p)
	}
	if p := plan(t, map[string]string{"package.json": `{}`, "bun.lock": "{}"}); p.Image != "oven/bun:1" {
		t.Fatalf("no version: %+v", p)
	}
}

func TestANodeRepoUsesItsLockfileAndNodeVersion(t *testing.T) {
	p := plan(t, map[string]string{"package.json": `{"engines":{"node":">=22"}}`, "package-lock.json": "{}", ".nvmrc": "v22.11.0\n"})
	if p.Toolchain != "node" || p.Image != "node:22.11.0" || p.Install != "npm ci" || p.Command != "npm run build" {
		t.Fatalf("%+v", p)
	}
}

// homeport.yaml says how, exactly as it does for a local deploy; build.image
// is the way in for any stack we don't detect.
func TestHomeportYamlOverridesTheDefaults(t *testing.T) {
	p := plan(t, map[string]string{
		"go.mod":        "module m\n\ngo 1.24\n",
		"homeport.yaml": "app: web\nbuild:\n  command: make release\n  artifact: dist/web\n",
	})
	if p.Image != "golang:1.24" || p.Command != "make release" || p.Artifact != "dist/web" {
		t.Fatalf("%+v", p)
	}
	p = plan(t, map[string]string{
		"homeport.yaml": "build:\n  image: rust:1.82-bookworm\n  command: cargo build --release && cp target/release/app server\n",
	})
	if p.Toolchain != "custom" || p.Image != "rust:1.82-bookworm" || !strings.HasPrefix(p.Command, "cargo build") || p.Artifact != "server" {
		t.Fatalf("custom: %+v", p)
	}
}

func TestAPlanItCantMakeSaysHow(t *testing.T) {
	for name, files := range map[string]map[string]string{
		"nothing to go on":         {"README.md": "hi"},
		"an image with no command": {"homeport.yaml": "build:\n  image: rust:1.82\n"},
		"a bad image":              {"homeport.yaml": "build:\n  image: \"rust; rm -rf /\"\n  command: x\n"},
		"an artifact outside":      {"go.mod": "module m\n\ngo 1.24\n", "homeport.yaml": "build:\n  artifact: ../../etc/passwd\n"},
		"an absolute artifact":     {"go.mod": "module m\n\ngo 1.24\n", "homeport.yaml": "build:\n  artifact: /etc/passwd\n"},
		"a bad go version":         {"go.mod": "module m\n\ngo 1.24;rm\n"},
		"bad yaml":                 {"homeport.yaml": "build: [\n"},
	} {
		if p, err := planBuild(repo(t, files)); err == nil {
			t.Errorf("%s: planned %+v", name, p)
		}
	}
}

// A repository's files are untrusted: the plan reads them and runs nothing,
// and a ${VAR} stays literal for the build's own shell (as for local builds).
func TestThePlanRunsNothingAndExpandsNothing(t *testing.T) {
	t.Setenv("SECRET", "host-secret")
	p := plan(t, map[string]string{"go.mod": "module m\n\ngo 1.24\n", "homeport.yaml": "build:\n  command: echo ${SECRET} && make\n"})
	if strings.Contains(p.Command, "host-secret") || !strings.Contains(p.Command, "${SECRET}") {
		t.Fatalf("command %q", p.Command)
	}
}

// A repository's file that is a symlink is never followed: it could point
// anywhere on the builder.
func TestSymlinksInTheRepositoryAreNotFollowed(t *testing.T) {
	dir := repo(t, map[string]string{"real.mod": "module m\n\ngo 1.24\n"})
	if err := os.Symlink(filepath.Join(dir, "real.mod"), filepath.Join(dir, "go.mod")); err != nil {
		t.Fatal(err)
	}
	if p, err := planBuild(dir); err == nil {
		t.Fatalf("followed a symlinked go.mod: %+v", p)
	}
}

// A hosted app runs sandboxed, so the plan carries how it runs from the same
// homeport.yaml: run, the release command and processes, checked by the
// sandbox's rules (args to ./bin, no shell).
func TestThePlanSaysHowTheAppRuns(t *testing.T) {
	p := plan(t, map[string]string{
		"go.mod": "module example.com/app\n\ngo 1.24.2\n",
		"homeport.yaml": "run: serve --port $PORT\nrelease: migrate\npost_release: ./bin warm\n" +
			"processes:\n  worker: work --queue default\n  ticker:\n    run: tick\n    memory: 128M\n",
	})
	if p.Run != "serve --port $PORT" || p.Release != "migrate" {
		t.Fatalf("run/release: %+v", p)
	}
	want := []planProcess{{Name: "ticker", Run: "tick", Memory: "128M"}, {Name: "worker", Run: "work --queue default"}}
	if len(p.Processes) != 2 || p.Processes[0] != want[0] || p.Processes[1] != want[1] {
		t.Fatalf("processes: %+v", p.Processes)
	}
	// nothing to run: the fields are left out
	if q := plan(t, map[string]string{"go.mod": "module x\n\ngo 1.24.2\n"}); q.Run != "" || q.Release != "" || q.Processes != nil {
		t.Fatalf("%+v", q)
	}
	for name, yml := range map[string]string{
		"shell release": "release: migrate && seed\n",
		"./bin release": "release: ./bin migrate\n",
		"bad run":       "run: serve; rm -rf /\n",
		"bad process":   "processes:\n  worker: work $QUEUE\n",
		"bad name":      "processes:\n  Worker: work\n",
	} {
		if _, err := planBuild(repo(t, map[string]string{"go.mod": "module x\n\ngo 1.24.2\n", "homeport.yaml": yml})); err == nil {
			t.Errorf("%s: planned", name)
		}
	}
}

// A PHP app builds on homeport's FrankenPHP base: PHP is already compiled,
// so the build checks the app's platform needs first (seconds, not a failed
// link later), installs, and embeds the app into a static binary.
func TestAPHPRepoBuildsOnTheFrankenPHPBase(t *testing.T) {
	p := plan(t, map[string]string{"composer.json": `{"require":{"php":"^8.3"}}`, "composer.lock": "{}"})
	if p.Toolchain != "php" || p.Image != frankenphpImage || p.Artifact != "server" ||
		p.Install != "composer check-platform-reqs --no-dev --lock && composer install --no-dev --optimize-autoloader --no-interaction" ||
		p.Command != "frankenphp-embed . server" {
		t.Fatalf("%+v", p)
	}
	// front-end assets (Vite) are built before the app is embedded
	p = plan(t, map[string]string{"composer.json": `{}`, "composer.lock": "{}",
		"package.json": `{"scripts":{"build":"vite build"}}`, "package-lock.json": "{}"})
	if p.Toolchain != "php" || !strings.HasSuffix(p.Install, " && bun install && bun run build") {
		t.Fatalf("assets: %+v", p)
	}
	if p := plan(t, map[string]string{"composer.json": `{}`, "composer.lock": "{}", "package.json": `{"scripts":{"dev":"vite"}}`, "bun.lock": "{}"}); strings.Contains(p.Install, "bun run build") {
		t.Fatalf("no build script: %+v", p)
	}
	if p := plan(t, map[string]string{"composer.json": `{}`, "composer.lock": "{}", "package.json": `{"scripts":{"build":"vite build"}}`, "bun.lock": "{}"}); !strings.Contains(p.Install, "bun install --frozen-lockfile") {
		t.Fatalf("bun lockfile: %+v", p)
	}
	// homeport.yaml still says how, and where the binary lands
	if p := plan(t, map[string]string{"composer.json": `{}`, "composer.lock": "{}", "homeport.yaml": "build:\n  artifact: dist/app\n"}); p.Command != "frankenphp-embed . dist/app" {
		t.Fatalf("artifact: %+v", p)
	}
	// without a lockfile the build isn't reproducible: say so
	if _, err := planBuild(repo(t, map[string]string{"composer.json": `{}`})); err == nil || !strings.Contains(err.Error(), "composer.lock") {
		t.Fatalf("no lockfile: %v", err)
	}
}
