package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// next-bun-compile 2 writes the binary to dist/app; 1.x wrote ./server. init points the artifact at what the
// installed major produces - the newest when the version can't be read.
func TestInitFindsTheBinaryNextBunCompileWrites(t *testing.T) {
	for spec, want := range map[string]string{
		"^2.0.0": "dist/app",
		"2.1.3":  "dist/app",
		"~3.0.0": "dist/app",
		"latest": "dist/app",
		"^1.5.3": "server",
		"1.0.0":  "server",
		"~1.2.0": "server",
	} {
		t.Run(spec, func(t *testing.T) {
			dir := t.TempDir()
			pkg := `{"name": "shop", "dependencies": {"next": "16.3.8"}, "devDependencies": {"next-bun-compile": "` + spec + `"}}`
			if err := os.WriteFile(filepath.Join(dir, "package.json"), []byte(pkg), 0o644); err != nil {
				t.Fatal(err)
			}
			t.Chdir(dir)
			p := detectProject()
			if p.kind != "next-bun-compile" || p.artifact != want {
				t.Fatalf("next-bun-compile %s: %s, artifact %q, want %q", spec, p.kind, p.artifact, want)
			}
		})
	}
}

func initIn(t *testing.T, pkg string) projectInfo {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "package.json"), []byte(pkg), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	return detectProject()
}

// SvelteKit's own Bun adapter compiles the server into one executable when
// buildOptions.compile is set, at build/server. svelte-bun-compile, ours
// before it, still works but says it's deprecated; the official adapter
// wins when a project has both.
func TestInitUsesSvelteKitsBunAdapter(t *testing.T) {
	p := initIn(t, `{"name": "shop", "devDependencies": {"@sveltejs/kit": "^3.0.0", "@sveltejs/adapter-bun": "^1.0.0"}}`)
	if p.kind != "sveltekit-adapter-bun" || p.artifact != "build/server" || p.build != "bun --bun run build" ||
		!strings.Contains(p.note, "buildOptions") || !strings.Contains(p.note, "compile") {
		t.Fatalf("adapter-bun: %+v", p)
	}
	old := initIn(t, `{"name": "shop", "devDependencies": {"svelte-bun-compile": "^0.1.0"}}`)
	if old.kind != "svelte-bun-compile" || old.artifact != "dist/app" || !strings.Contains(old.note, "deprecated") ||
		!strings.Contains(old.note, "@sveltejs/adapter-bun") {
		t.Fatalf("svelte-bun-compile: %+v", old)
	}
	both := initIn(t, `{"name": "shop", "devDependencies": {"svelte-bun-compile": "^0.1.0", "@sveltejs/adapter-bun": "^1.0.0"}}`)
	if both.kind != "sveltekit-adapter-bun" {
		t.Fatalf("both: %+v", both)
	}
}
