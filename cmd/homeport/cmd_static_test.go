package main

import (
	"os"
	"path/filepath"
	"testing"
)

func writeFiles(t *testing.T, dir string, files ...string) {
	t.Helper()
	for _, f := range files {
		p := filepath.Join(dir, f)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestDetectSPA(t *testing.T) {
	cases := []struct {
		name  string
		files []string
		spa   bool
	}{
		{"sveltekit/netlify 200.html", []string{"index.html", "200.html", "assets/app.js"}, true},
		{"vite lone index", []string{"index.html", "assets/app.js", "favicon.ico"}, true},
		{"mpa multiple pages", []string{"index.html", "about.html", "blog/index.html"}, false},
		{"next export nested", []string{"index.html", "posts/first.html", "posts/second.html"}, false},
		{"200.html wins over many pages", []string{"index.html", "about.html", "200.html"}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			writeFiles(t, dir, c.files...)
			if got := detectSPA(dir); got != c.spa {
				t.Errorf("detectSPA(%v) = %v, want %v", c.files, got, c.spa)
			}
		})
	}
}
