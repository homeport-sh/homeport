package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// buildPlan is what a hosted build runs: in which image, which install step
// (if any), which build command, and where the binary lands. It's read from
// the repository's own files - homeport.yaml's build: section, exactly as a
// local deploy reads it, and the toolchain's own files for what it leaves out.
type buildPlan struct {
	Toolchain string `json:"toolchain"` // go, bun, node, or custom (build.image)
	Image     string `json:"image"`
	Install   string `json:"install,omitempty"`
	Command   string `json:"command"`
	Artifact  string `json:"artifact"` // relative to the repository
}

var (
	versionRe = regexp.MustCompile(`^[0-9]{1,3}(\.[0-9]{1,4}){0,2}$`)
	imageRe   = regexp.MustCompile(`^[a-z0-9]+([._/-][a-z0-9]+)*(:[A-Za-z0-9._-]{1,128})?(@sha256:[0-9a-f]{64})?$`)
)

// cmdBuildPlan prints the plan for a repository (default: here), as JSON.
// Builders run it on a checkout; anyone can run it to see what a hosted
// build will do.
func cmdBuildPlan(args []string) error {
	dir := "."
	if len(args) > 0 {
		dir = args[0]
	}
	p, err := planBuild(dir)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(p)
}

// planBuild reads a repository and runs nothing from it: its files are
// untrusted. A ${VAR} stays literal, for the build's own shell to expand.
func planBuild(dir string) (buildPlan, error) {
	var cfg struct {
		Build buildConfig `yaml:"build"`
	}
	if b, err := readSmall(dir, configFile); err == nil {
		if err := yaml.Unmarshal(b, &cfg); err != nil {
			return buildPlan{}, fmt.Errorf("%s: %w", configFile, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return buildPlan{}, err
	}

	p := buildPlan{Command: cfg.Build.Command, Artifact: cfg.Build.Artifact}
	if p.Artifact == "" {
		p.Artifact = "server"
	}
	if clean := filepath.Clean(p.Artifact); filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, "../") {
		return buildPlan{}, fmt.Errorf("build.artifact %q must be a path inside the repository", p.Artifact)
	}

	switch {
	case cfg.Build.Image != "":
		if !imageRe.MatchString(cfg.Build.Image) || len(cfg.Build.Image) > 255 {
			return buildPlan{}, fmt.Errorf("build.image %q isn't an image reference", cfg.Build.Image)
		}
		if p.Command == "" {
			return buildPlan{}, errors.New("build.image needs a build.command: what to run in it")
		}
		p.Toolchain, p.Image = "custom", cfg.Build.Image
	case exists(dir, "go.mod"):
		v, err := goVersion(dir)
		if err != nil {
			return buildPlan{}, err
		}
		p.Toolchain, p.Image = "go", "golang:"+v
		if p.Command == "" {
			p.Command = `CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o ` + p.Artifact + " ."
		}
	case exists(dir, "package.json") && (exists(dir, "bun.lock") || exists(dir, "bun.lockb") || packageManager(dir, "bun") != ""):
		v := packageManager(dir, "bun")
		if v == "" {
			v = firstLine(dir, ".bun-version")
		}
		if v == "" {
			v = "1"
		}
		if !versionRe.MatchString(v) {
			return buildPlan{}, fmt.Errorf("bun version %q isn't a version", v)
		}
		p.Toolchain, p.Image, p.Install = "bun", "oven/bun:"+v, "bun install --frozen-lockfile"
		if p.Command == "" {
			p.Command = "bun run build"
		}
	case exists(dir, "package.json") && exists(dir, "package-lock.json"):
		v := strings.TrimPrefix(firstLine(dir, ".nvmrc"), "v")
		if v == "" {
			v = "22"
		}
		if !versionRe.MatchString(v) {
			return buildPlan{}, fmt.Errorf(".nvmrc %q isn't a version", v)
		}
		p.Toolchain, p.Image, p.Install = "node", "node:"+v, "npm ci"
		if p.Command == "" {
			p.Command = "npm run build"
		}
	default:
		return buildPlan{}, errors.New("can't tell how to build this repository: no go.mod, no bun or npm lockfile; " +
			"set build.image and build.command in homeport.yaml")
	}
	return p, nil
}

var (
	goToolchainRe = regexp.MustCompile(`(?m)^toolchain\s+go(\S+)\s*$`)
	goLineRe      = regexp.MustCompile(`(?m)^go\s+(\S+)\s*$`)
)

func goVersion(dir string) (string, error) {
	b, err := readSmall(dir, "go.mod")
	if err != nil {
		return "", err
	}
	v := ""
	if m := goToolchainRe.FindSubmatch(b); m != nil {
		v = string(m[1])
	} else if m := goLineRe.FindSubmatch(b); m != nil {
		v = string(m[1])
	}
	if !versionRe.MatchString(v) {
		return "", fmt.Errorf("go.mod's Go version %q isn't a version", v)
	}
	return v, nil
}

// packageManager is the version in package.json's "packageManager":
// "<name>@<version>", or "".
func packageManager(dir, name string) string {
	b, err := readSmall(dir, "package.json")
	if err != nil {
		return ""
	}
	var pkg struct {
		PackageManager string `json:"packageManager"`
	}
	if json.Unmarshal(b, &pkg) != nil {
		return ""
	}
	v, ok := strings.CutPrefix(pkg.PackageManager, name+"@")
	if !ok {
		return ""
	}
	v, _, _ = strings.Cut(v, "+") // a pinned hash after the version
	return v
}

func firstLine(dir, name string) string {
	b, err := readSmall(dir, name)
	if err != nil {
		return ""
	}
	line, _, _ := strings.Cut(string(b), "\n")
	return strings.TrimSpace(line)
}

func exists(dir, name string) bool {
	st, err := os.Lstat(filepath.Join(dir, name))
	return err == nil && st.Mode().IsRegular()
}

// readSmall reads a regular file of the repository, at most 1 MiB, never
// through a symlink (which could point anywhere on the builder).
func readSmall(dir, name string) ([]byte, error) {
	p := filepath.Join(dir, name)
	st, err := os.Lstat(p)
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() {
		return nil, fmt.Errorf("%s is not a regular file", name)
	}
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(io.LimitReader(f, 1<<20))
}
