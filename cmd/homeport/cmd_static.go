package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// detectSPA decides whether a built static directory is a single-page app that
// needs a catch-all fallback route. Conventions it keys off:
//   - 200.html at the root → SvelteKit adapter-static / Netlify SPA fallback.
//   - a lone root index.html (no other .html anywhere) → Vite / CRA SPA.
//   - anything else (multiple .html: Next `output: export`, Astro, Hugo,
//     Docusaurus) → a multi-page site, served file-for-file, no fallback.
//
// homeportd picks the concrete fallback file (200.html vs index.html) itself
// from the extracted release; here we only need the yes/no.
func detectSPA(dir string) bool {
	if st, err := os.Stat(filepath.Join(dir, "200.html")); err == nil && !st.IsDir() {
		return true
	}
	htmlCount, onlyRootIndex := 0, true
	_ = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(d.Name(), ".html") {
			return nil
		}
		htmlCount++
		if rel, _ := filepath.Rel(dir, p); rel != "index.html" {
			onlyRootIndex = false
		}
		return nil
	})
	return htmlCount == 1 && onlyRootIndex
}

// deployStatic ships a directory of files (no process): optional build, resolve
// the SPA decision, register, tar+stream the dir through homeportd's upload verb,
// then activate (an atomic symlink flip + Caddy reload — instant, no downtime).
func deployStatic(cfg *config, args []string) error {
	if cfg.Build.Command != "" && !hasFlag(args, "--no-build") {
		step("building: %s", cfg.Build.Command)
		if err := run(nil, "sh", "-c", cfg.Build.Command); err != nil {
			return fmt.Errorf("build failed: %w", err)
		}
	}

	if fi, err := os.Stat(cfg.Static); err != nil || !fi.IsDir() {
		return fmt.Errorf("static: %q is not a directory — did the build produce it?", cfg.Static)
	}
	if st, err := os.Stat(filepath.Join(cfg.Static, "index.html")); err != nil || st.IsDir() {
		return fmt.Errorf("static: no index.html in %q — a site needs an entry page", cfg.Static)
	}

	if cfg.SPA != nil {
		cfg.spaResolved = *cfg.SPA
	} else {
		cfg.spaResolved = detectSPA(cfg.Static)
	}
	mode := "static, multi-page"
	if cfg.spaResolved {
		mode = "static, SPA"
	}

	id := releaseID()
	step("registering %s (%s) on %s", cfg.App, mode, cfg.Server)
	if err := cfg.register(); err != nil {
		return fmt.Errorf("app registration failed — did you run `homeport bootstrap` on this server? (%w)", err)
	}

	step("uploading %s → release %s", cfg.Static, id)
	tarball, err := os.CreateTemp("", "homeport-static-*.tar.gz")
	if err != nil {
		return err
	}
	defer os.Remove(tarball.Name())
	tarball.Close()
	if err := run(nil, "tar", "-czf", tarball.Name(), "-C", cfg.Static, "."); err != nil {
		return fmt.Errorf("could not archive %s: %w", cfg.Static, err)
	}
	if err := sshRunInFile(cfg.Server, cfg.homeportd("upload-static", cfg.App, id), tarball.Name()); err != nil {
		return fmt.Errorf("upload failed: %w", err)
	}

	step("activating (symlink flip + Caddy reload)")
	if err := sshRun(cfg.Server, cfg.homeportd("activate", cfg.App, id)); err != nil {
		return fmt.Errorf("activation failed: %w", err)
	}
	step("deployed → https://%s%s", cfg.Domain, cfg.Path)
	return nil
}
