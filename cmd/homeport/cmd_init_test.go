package main

import (
	"os"
	"path/filepath"
	"testing"
)

// next-bun-compile 2 writes the binary to dist/app (as svelte-bun-compile
// does); 1.x wrote ./server. init points the artifact at what the
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
