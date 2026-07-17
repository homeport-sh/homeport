package main

import (
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

const configFile = "homeport.yaml"

type buildConfig struct {
	Command  string `yaml:"command"`
	Artifact string `yaml:"artifact"`
}

type healthConfig struct {
	Path string `yaml:"path"`
}

type config struct {
	App    string       `yaml:"app"`
	Server string       `yaml:"server"`
	Domain string       `yaml:"domain"`
	Build  buildConfig  `yaml:"build"`
	Health healthConfig `yaml:"health"`
}

// These mirror homeportd's server-side validation — fail fast with a good
// message locally instead of a terse remote one.
var (
	appRe     = regexp.MustCompile(`^[a-z][a-z0-9-]{0,19}$`)
	domainRe  = regexp.MustCompile(`^[a-z0-9]([a-z0-9.-]{0,250}[a-z0-9])?$`)
	healthRe  = regexp.MustCompile(`^/[A-Za-z0-9._/-]*$`)
	releaseRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$`)
)

func loadConfig() (*config, error) {
	data, err := os.ReadFile(configFile)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("no %s in this directory — run `homeport init` first", configFile)
		}
		return nil, err
	}
	cfg := &config{}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("%s: %w", configFile, err)
	}
	if cfg.Build.Command == "" {
		cfg.Build.Command = "bun run build"
	}
	if cfg.Build.Artifact == "" {
		cfg.Build.Artifact = "server"
	}
	if cfg.Health.Path == "" {
		cfg.Health.Path = "/"
	}
	switch {
	case !appRe.MatchString(cfg.App):
		return nil, fmt.Errorf("%s: app %q must be lowercase letters, digits, dashes, max 20 chars", configFile, cfg.App)
	case !strings.Contains(cfg.Server, "@"):
		return nil, fmt.Errorf("%s: server should look like deploy@1.2.3.4 (got %q)", configFile, cfg.Server)
	case !domainRe.MatchString(cfg.Domain):
		return nil, fmt.Errorf("%s: %q doesn't look like a domain", configFile, cfg.Domain)
	case !healthRe.MatchString(cfg.Health.Path):
		return nil, fmt.Errorf("%s: health.path must start with / and contain no spaces", configFile)
	}
	return cfg, nil
}

// homeportd builds the remote command line for the root-side helper. Every
// argument that reaches here is charset-validated, so plain joining is safe.
func (c *config) homeportd(args ...string) string {
	return "sudo /usr/local/bin/homeportd " + strings.Join(args, " ")
}

func (c *config) host() string {
	return c.Server[strings.Index(c.Server, "@")+1:]
}

// releaseID is sortable (UTC timestamp first) so homeportd can prune oldest
// and roll back to "the previous one" by lexical order alone.
func releaseID() string {
	id := time.Now().UTC().Format("20060102-150405")
	out, err := exec.Command("git", "rev-parse", "--short", "HEAD").Output()
	if err == nil {
		if sha := strings.TrimSpace(string(out)); sha != "" {
			id += "-" + sha
		}
	}
	return id
}
