package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
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

type resourcesConfig struct {
	Memory string `yaml:"memory"`
	CPU    string `yaml:"cpu"`
}

type autoscaleConfig struct {
	Min       int `yaml:"min"`
	Max       int `yaml:"max"`
	TargetCPU int `yaml:"target_cpu"`
}

// on reports whether autoscaling is configured (max set).
func (a autoscaleConfig) on() bool { return a.Max > 0 }

type config struct {
	App         string          `yaml:"app"`
	Server      string          `yaml:"server"`
	Domain      string          `yaml:"domain"`
	Run         string          `yaml:"run"`
	Release     string          `yaml:"release"`
	PostRelease string          `yaml:"post_release"`
	Internal    bool            `yaml:"internal"`
	Idle        bool            `yaml:"idle"`
	IdleTimeout string          `yaml:"idle_timeout"`
	Replicas    int             `yaml:"replicas"`
	Autoscale   autoscaleConfig `yaml:"autoscale"`
	Build       buildConfig     `yaml:"build"`
	Health      healthConfig    `yaml:"health"`
	Resources   resourcesConfig `yaml:"resources"`
}

// These mirror homeportd's server-side validation — fail fast with a good
// message locally instead of a terse remote one.
var (
	appRe     = regexp.MustCompile(`^[a-z][a-z0-9-]{0,19}$`)
	domainRe  = regexp.MustCompile(`^[a-z0-9]([a-z0-9.-]{0,250}[a-z0-9])?$`)
	healthRe  = regexp.MustCompile(`^/[A-Za-z0-9._/-]*$`)
	releaseRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$`)
	memoryRe  = regexp.MustCompile(`^[0-9]+[KMG]$`)
	cpuRe     = regexp.MustCompile(`^[0-9]+%$`)
	timeoutRe = regexp.MustCompile(`^[0-9]+[smh]$`)
	// run: launch args appended to the binary in ExecStart. exec (no shell),
	// so no shell metachars; only $PORT/$HOST are substituted server-side.
	runRe = regexp.MustCompile(`^[A-Za-z0-9 ._:/=@,+${}-]*$`)
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
	cfg.Server = normalizeServer(cfg.Server)
	// An empty domain implies internal, and vice versa — normalize so the
	// rest of the CLI (and homeportd) can key on either.
	if cfg.Domain == "" {
		cfg.Internal = true
	}
	switch {
	case !appRe.MatchString(cfg.App):
		return nil, fmt.Errorf("%s: app %q must be lowercase letters, digits, dashes, max 20 chars", configFile, cfg.App)
	case !strings.Contains(cfg.Server, "@"):
		return nil, fmt.Errorf("%s: server should look like deploy@1.2.3.4 (got %q)", configFile, cfg.Server)
	case cfg.Internal && cfg.Domain != "":
		return nil, fmt.Errorf("%s: set either a domain (public) or internal: true, not both", configFile)
	case !cfg.Internal && !domainRe.MatchString(cfg.Domain):
		return nil, fmt.Errorf("%s: %q doesn't look like a domain (or set internal: true for a private app)", configFile, cfg.Domain)
	case !healthRe.MatchString(cfg.Health.Path):
		return nil, fmt.Errorf("%s: health.path must start with / and contain no spaces", configFile)
	case cfg.Resources.Memory != "" && !memoryRe.MatchString(cfg.Resources.Memory):
		return nil, fmt.Errorf("%s: resources.memory must be a number with K/M/G suffix (e.g. 512M, 1G), got %q", configFile, cfg.Resources.Memory)
	case cfg.Resources.CPU != "" && !cpuRe.MatchString(cfg.Resources.CPU):
		return nil, fmt.Errorf("%s: resources.cpu must be a percentage (e.g. 150%% for 1.5 cores), got %q", configFile, cfg.Resources.CPU)
	case cfg.IdleTimeout != "" && !timeoutRe.MatchString(cfg.IdleTimeout):
		return nil, fmt.Errorf("%s: idle_timeout must be a number with s/m/h suffix (e.g. 300s, 5m), got %q", configFile, cfg.IdleTimeout)
	case cfg.IdleTimeout != "" && !cfg.Idle:
		return nil, fmt.Errorf("%s: idle_timeout is set but idle is not true", configFile)
	case cfg.Replicas < 0 || cfg.Replicas > 20:
		return nil, fmt.Errorf("%s: replicas must be 1-20 (got %d)", configFile, cfg.Replicas)
	case cfg.Replicas > 1 && cfg.Internal:
		return nil, fmt.Errorf("%s: replicas>1 needs a domain (Caddy load-balances them) — remove internal", configFile)
	case cfg.Replicas > 1 && cfg.Idle:
		return nil, fmt.Errorf("%s: replicas and idle are mutually exclusive (idle is 0<->1, replicas is 1<->N)", configFile)
	case cfg.Autoscale.on() && cfg.Idle:
		return nil, fmt.Errorf("%s: autoscale and idle are mutually exclusive", configFile)
	case cfg.Autoscale.on() && cfg.Internal:
		return nil, fmt.Errorf("%s: autoscale needs a domain (Caddy load-balances the replicas)", configFile)
	case cfg.Autoscale.on() && cfg.Replicas > 1:
		return nil, fmt.Errorf("%s: set either replicas (fixed) or autoscale (min/max), not both", configFile)
	case cfg.Autoscale.on() && (cfg.Autoscale.Min < 1 || cfg.Autoscale.Max > 20 || cfg.Autoscale.Min > cfg.Autoscale.Max):
		return nil, fmt.Errorf("%s: autoscale needs 1 <= min <= max <= 20 (got min=%d max=%d)", configFile, cfg.Autoscale.Min, cfg.Autoscale.Max)
	case cfg.Autoscale.on() && cfg.Autoscale.TargetCPU != 0 && (cfg.Autoscale.TargetCPU < 1 || cfg.Autoscale.TargetCPU > 100):
		return nil, fmt.Errorf("%s: autoscale.target_cpu must be 1-100 (got %d)", configFile, cfg.Autoscale.TargetCPU)
	case cfg.Run != "" && !runRe.MatchString(cfg.Run):
		return nil, fmt.Errorf("%s: run has unsupported characters (letters, digits, spaces, . _ : / = @ , + - ${} only)", configFile)
	case cfg.Run != "" && strings.Contains(stripRunVars(cfg.Run), "$"):
		return nil, fmt.Errorf("%s: run may only reference $PORT and $HOST, no other variables", configFile)
	case strings.ContainsAny(cfg.Release, "\n\r"):
		return nil, fmt.Errorf("%s: release must be a single line (chain steps with && )", configFile)
	case strings.ContainsAny(cfg.PostRelease, "\n\r"):
		return nil, fmt.Errorf("%s: post_release must be a single line (chain steps with && )", configFile)
	}
	if cfg.Replicas == 0 {
		cfg.Replicas = 1
	}
	if cfg.Autoscale.on() && cfg.Autoscale.TargetCPU == 0 {
		cfg.Autoscale.TargetCPU = 70
	}
	return cfg, nil
}

// homeportd builds the remote command line for the root-side helper. Every
// argument that reaches here is charset-validated, so plain joining is safe.
func (c *config) homeportd(args ...string) string {
	return "sudo /usr/local/bin/homeportd " + strings.Join(args, " ")
}

// addArgs builds the positional `homeportd add` command line from the config.
// Shared by deploy and secrets so registration is identical either way. "-"
// is the unset placeholder; add is idempotent, so calling it repeatedly is
// safe (it rewrites units/config without restarting a running app).
func (c *config) addArgs() []string {
	idle := "-"
	if c.Idle {
		idle = "true"
	}
	autoscale := "-"
	if c.Autoscale.on() {
		autoscale = fmt.Sprintf("%d:%d:%d", c.Autoscale.Min, c.Autoscale.Max, c.Autoscale.TargetCPU)
	}
	// run/release/post_release args carry spaces, so they travel base64-encoded
	// as single positional tokens
	run, release, postRelease := "-", "-", "-"
	if c.Run != "" {
		run = base64.StdEncoding.EncodeToString([]byte(c.Run))
	}
	if c.Release != "" {
		release = base64.StdEncoding.EncodeToString([]byte(c.Release))
	}
	if c.PostRelease != "" {
		postRelease = base64.StdEncoding.EncodeToString([]byte(c.PostRelease))
	}
	return []string{
		"add", c.App,
		dashIfEmpty(c.Domain),
		c.Health.Path,
		dashIfEmpty(c.Resources.Memory),
		dashIfEmpty(c.Resources.CPU),
		idle,
		dashIfEmpty(c.IdleTimeout),
		strconv.Itoa(c.Replicas),
		autoscale,
		run,
		release,
		postRelease,
	}
}

// stripRunVars removes the two supported variables so a leftover "$" can be
// detected (any other $VAR is rejected — only $PORT/$HOST are substituted).
func stripRunVars(s string) string {
	for _, v := range []string{"${PORT}", "$PORT", "${HOST}", "$HOST"} {
		s = strings.ReplaceAll(s, v, "")
	}
	return s
}

// register ensures the app exists on the server (idempotent). Lets `secrets
// push` seed env before the first deploy — the app must be registered for its
// env file to exist.
func (c *config) register() error {
	return sshRun(c.Server, c.homeportd(c.addArgs()...))
}

func (c *config) host() string {
	return c.Server[strings.Index(c.Server, "@")+1:]
}

// dashIfEmpty renders an optional positional arg: "-" is homeportd's
// placeholder for "unset" so trailing optional args keep their position.
func dashIfEmpty(s string) string {
	if s == "" {
		return "-"
	}
	return s
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
