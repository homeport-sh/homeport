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
