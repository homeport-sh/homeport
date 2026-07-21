package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"sort"
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
	Path    string `yaml:"path"`
	Timeout string `yaml:"timeout"`
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

// flexStrings accepts a YAML scalar ("a.com" or "a.com, b.com") or sequence
// ([a.com, b.com]) — so `domain:` reads naturally in every shape.
type flexStrings []string

func (f *flexStrings) UnmarshalYAML(n *yaml.Node) error {
	switch n.Kind {
	case yaml.ScalarNode:
		var s string
		if err := n.Decode(&s); err != nil {
			return err
		}
		for _, part := range strings.Split(s, ",") {
			if p := strings.TrimSpace(part); p != "" {
				*f = append(*f, p)
			}
		}
	case yaml.SequenceNode:
		var list []string
		if err := n.Decode(&list); err != nil {
			return err
		}
		for _, s := range list {
			if p := strings.TrimSpace(s); p != "" {
				*f = append(*f, p)
			}
		}
	default:
		return fmt.Errorf("domain must be a string or a list of strings")
	}
	return nil
}

type config struct {
	App     string      `yaml:"app"`
	Server  string      `yaml:"server"`
	Domains flexStrings `yaml:"domain"` // one or more; the FIRST is canonical
	// Domain is the canonical (first) domain — what status prints, what
	// redirect_from targets, what gateway hosts key on. Set from Domains.
	Domain string `yaml:"-"`
	Path        string          `yaml:"path"`
	Static      string          `yaml:"static"` // a directory → Caddy file_server, no process
	SPA         *bool           `yaml:"spa"`    // nil = auto-detect; true/false override the fallback
	// alias domains that 301 to this app's domain (www → apex, brand domains).
	// Each gets its own cert + redirect block, and lives/dies with the app.
	RedirectFrom []string `yaml:"redirect_from"`
	Run         string          `yaml:"run"`
	Release     string          `yaml:"release"`
	PostRelease string          `yaml:"post_release"`
	Sandbox     string          `yaml:"sandbox"`
	Strategy    string          `yaml:"strategy"`
	TLS         string          `yaml:"tls"`           // "auto" (default) | "manual" (BYO cert) | "dns:<provider>" (DNS-01 via a caddy-dns plugin)
	DNSTokenEnv string          `yaml:"dns_token_env"` // env var holding the DNS provider token (default HOMEPORT_DNS_<PROVIDER>); "none" for SDK-env providers
	Internal    bool            `yaml:"internal"`
	Idle        bool            `yaml:"idle"`
	IdleTimeout string          `yaml:"idle_timeout"`
	Replicas    int             `yaml:"replicas"`
	Autoscale   autoscaleConfig `yaml:"autoscale"`
	Build       buildConfig     `yaml:"build"`
	Health      healthConfig    `yaml:"health"`
	Resources   resourcesConfig `yaml:"resources"`
	// extra response headers, verbatim; homeport never sets any on its own.
	// keyed by path glob ("/*" = all paths), then header name -> value.
	Headers map[string]map[string]string `yaml:"headers"`

	// spaResolved is the concrete SPA decision for this deploy (SPA overridden
	// or auto-detected from the static dir); set by cmdDeploy, read by addArgs.
	spaResolved bool
}

// isStatic reports whether this is a static-files app (Caddy file_server, no
// process/unit/health-check).
func (c *config) isStatic() bool { return c.Static != "" }

// These mirror homeportd's server-side validation — fail fast with a good
// message locally instead of a terse remote one.
var (
	appRe = regexp.MustCompile(`^[a-z][a-z0-9-]{0,19}$`)
	// server is passed as an argv token to ssh/scp; the first char MUST be
	// alphanumeric — a leading "-" (e.g. "-oProxyCommand=…@host") would be
	// parsed by ssh as an OPTION → local command execution.
	serverRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9._-]*$`)
	domainRe = regexp.MustCompile(`^[a-z0-9]([a-z0-9.-]{0,250}[a-z0-9])?$`)
	healthRe = regexp.MustCompile(`^/[A-Za-z0-9._/-]*$`)
	// path: mount prefix under a shared domain — leading slash, one or more
	// segments, no trailing slash, no spaces (Caddy handle_path matcher).
	pathRe    = regexp.MustCompile(`^/[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$`)
	releaseRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$`)
	memoryRe  = regexp.MustCompile(`^[0-9]+[KMG]$`)
	cpuRe     = regexp.MustCompile(`^[0-9]+%$`)
	timeoutRe = regexp.MustCompile(`^[0-9]+[smh]$`)

	// response-header name/value: a name is a plain token; a value is one line of
	// printable ASCII (quotes/braces/backslashes are rejected separately, as they
	// could break out of the generated Caddyfile).
	headerNameRe  = regexp.MustCompile(`^[A-Za-z0-9-]+$`)
	headerValueRe = regexp.MustCompile(`^[ -~]*$`)
	// path glob for scoping headers: "*"/"/*" (all) or a "/dir/*" prefix.
	headerGlobRe = regexp.MustCompile(`^(\*|/[A-Za-z0-9._*/~-]*)$`)
	// tls: dns:<provider> — the caddy-dns plugin's short name (dns:cloudflare)
	dnsProviderRe = regexp.MustCompile(`^dns:[a-z0-9-]{1,40}$`)
	envNameRe     = regexp.MustCompile(`^[A-Z][A-Z0-9_]{0,63}$`)
	// run: launch args appended to the binary in ExecStart. exec (no shell),
	// so no shell metachars; only $PORT/$HOST are substituted server-side.
	runRe = regexp.MustCompile(`^[A-Za-z0-9 ._:/=@,+${}-]*$`)
	// an empty `${}` or an unterminated `${…` with no closing brace
	malformedRefRe = regexp.MustCompile(`\$\{\}|\$\{[^}]*$`)
	// static: a relative directory. A leading "./" is fine; no "..", no
	// absolute paths (validated separately for the traversal check).
	staticDirRe = regexp.MustCompile(`^\.?/?[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$`)
)

func loadConfig() (*config, error) {
	data, err := os.ReadFile(configFile)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("no %s in this directory — run `homeport init` first", configFile)
		}
		return nil, err
	}
	return parseConfig(data)
}

// parseConfig turns raw homeport.yaml bytes into a validated config. Split from
// loadConfig (which only adds file I/O) so the whole parse/expand/validate path
// is unit-testable without touching the filesystem.
func parseConfig(data []byte) (*config, error) {
	cfg := &config{}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("%s: %w", configFile, err)
	}
	// Expand ${VAR}/$VAR from the environment in the parameterizable fields, so
	// one committed homeport.yaml serves staging/prod via CI env. Command fields
	// (run/release/post_release/build) are left literal on purpose — run: uses
	// $PORT/$HOST for homeport's own server-side substitution, which env
	// expansion must not clobber. A referenced-but-unset var is a hard error.
	for _, f := range []struct {
		name string
		ptr  *string
	}{
		{"server", &cfg.Server},
		{"app", &cfg.App},
		{"path", &cfg.Path},
		{"idle_timeout", &cfg.IdleTimeout},
		{"resources.memory", &cfg.Resources.Memory},
		{"resources.cpu", &cfg.Resources.CPU},
	} {
		v, err := expandEnvStrict(f.name, *f.ptr)
		if err != nil {
			return nil, err
		}
		*f.ptr = v
	}
	// binary-app defaults — a static site has no build step by default (plain
	// HTML) and no binary artifact.
	if !cfg.isStatic() {
		if cfg.Build.Command == "" {
			cfg.Build.Command = "bun run build"
		}
		if cfg.Build.Artifact == "" {
			cfg.Build.Artifact = "server"
		}
	}
	if cfg.Health.Path == "" {
		cfg.Health.Path = "/"
	}
	cfg.Server = normalizeServer(cfg.Server)
	// domain: accepts one or many — env-expand each, then the FIRST becomes
	// the canonical cfg.Domain and the rest serve as extra hostnames on the
	// same site block (a cert per hostname, courtesy of Caddy).
	for i := range cfg.Domains {
		v, err := expandEnvStrict("domain", cfg.Domains[i])
		if err != nil {
			return nil, err
		}
		cfg.Domains[i] = v
	}
	if len(cfg.Domains) > 0 {
		cfg.Domain = cfg.Domains[0]
	}
	// An empty domain implies internal, and vice versa — normalize so the
	// rest of the CLI (and homeportd) can key on either.
	if cfg.Domain == "" {
		cfg.Internal = true
	}
	switch {
	case !appRe.MatchString(cfg.App):
		return nil, fmt.Errorf("%s: app %q must be lowercase letters, digits, dashes, max 20 chars", configFile, cfg.App)
	case !serverRe.MatchString(cfg.Server):
		return nil, fmt.Errorf("%s: server should look like deploy@1.2.3.4 (got %q)", configFile, cfg.Server)
	case cfg.Internal && cfg.Domain != "":
		return nil, fmt.Errorf("%s: set either a domain (public) or internal: true, not both", configFile)
	case !cfg.Internal && !domainRe.MatchString(cfg.Domain):
		return nil, fmt.Errorf("%s: %q doesn't look like a domain (or set internal: true for a private app)", configFile, cfg.Domain)
	case cfg.Path != "" && cfg.Internal:
		return nil, fmt.Errorf("%s: path mounts under a shared public domain — remove internal", configFile)
	case cfg.Path != "" && cfg.Domain == "":
		return nil, fmt.Errorf("%s: path is set but domain is not — path mounts an app under a shared domain (e.g. domain: api.example.com, path: /geo-api)", configFile)
	case cfg.Path != "" && !pathRe.MatchString(cfg.Path):
		return nil, fmt.Errorf("%s: path must look like /geo-api (leading slash, no trailing slash, no spaces), got %q", configFile, cfg.Path)
	case !healthRe.MatchString(cfg.Health.Path):
		return nil, fmt.Errorf("%s: health.path must start with / and contain no spaces", configFile)
	case cfg.Health.Timeout != "" && !timeoutRe.MatchString(cfg.Health.Timeout):
		return nil, fmt.Errorf("%s: health.timeout must be a number with s/m/h suffix (e.g. 30s, 2m), got %q", configFile, cfg.Health.Timeout)
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
	case cfg.Replicas > 1 && cfg.Idle:
		return nil, fmt.Errorf("%s: replicas and idle are mutually exclusive (idle is 0<->1, replicas is 1<->N)", configFile)
	case cfg.Autoscale.on() && cfg.Idle:
		return nil, fmt.Errorf("%s: autoscale and idle are mutually exclusive", configFile)
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
	case cfg.Sandbox != "" && cfg.Sandbox != "strict" && cfg.Sandbox != "relaxed":
		return nil, fmt.Errorf("%s: sandbox must be 'strict' (default) or 'relaxed' (for binaries that run their own sandbox, e.g. a browser), got %q", configFile, cfg.Sandbox)
	case cfg.Strategy != "" && cfg.Strategy != "blue-green" && cfg.Strategy != "recreate":
		return nil, fmt.Errorf("%s: strategy must be 'blue-green' (default, zero-downtime) or 'recreate' (restart in place — for singleton apps that can't run two instances), got %q", configFile, cfg.Strategy)
	case cfg.TLS != "" && cfg.TLS != "auto" && cfg.TLS != "manual" && !dnsProviderRe.MatchString(cfg.TLS):
		return nil, fmt.Errorf("%s: tls must be 'auto' (default), 'manual' (bring-your-own cert via `homeport tls set`), or 'dns:<provider>' (DNS-01 via a caddy-dns plugin, e.g. dns:cloudflare), got %q", configFile, cfg.TLS)
	case (cfg.TLS == "manual" || strings.HasPrefix(cfg.TLS, "dns:")) && (cfg.Internal || cfg.Domain == ""):
		return nil, fmt.Errorf("%s: tls: %s needs a public domain — there's nothing to serve a cert for on an internal app", configFile, cfg.TLS)
	case (cfg.TLS == "manual" || strings.HasPrefix(cfg.TLS, "dns:")) && cfg.Path != "":
		return nil, fmt.Errorf("%s: tls: %s isn't for path-mounted apps — the gateway host owns its TLS", configFile, cfg.TLS)
	case cfg.DNSTokenEnv != "" && !strings.HasPrefix(cfg.TLS, "dns:"):
		return nil, fmt.Errorf("%s: dns_token_env only applies with tls: dns:<provider>", configFile)
	case cfg.DNSTokenEnv != "" && cfg.DNSTokenEnv != "none" && !envNameRe.MatchString(cfg.DNSTokenEnv):
		return nil, fmt.Errorf("%s: dns_token_env must be an env var name (A-Z, digits, _) or 'none', got %q", configFile, cfg.DNSTokenEnv)
	case cfg.isStatic() && cfg.Internal:
		return nil, fmt.Errorf("%s: a static site needs a domain — Caddy serves it publicly", configFile)
	case cfg.isStatic() && cfg.Path != "":
		return nil, fmt.Errorf("%s: static path-mounting isn't supported yet — give the static site its own domain", configFile)
	case cfg.isStatic() && (cfg.Run != "" || cfg.Idle || cfg.Replicas > 1 || cfg.Autoscale.on() || cfg.Sandbox != "" || cfg.Strategy != "" || cfg.Resources.Memory != "" || cfg.Resources.CPU != ""):
		return nil, fmt.Errorf("%s: static is files-only (no process) — remove run/idle/replicas/autoscale/sandbox/strategy/resources", configFile)
	case cfg.isStatic() && (!staticDirRe.MatchString(cfg.Static) || strings.Contains(cfg.Static, "..")):
		return nil, fmt.Errorf("%s: static must be a relative directory (e.g. ./dist, no .. or leading /), got %q", configFile, cfg.Static)
	case len(cfg.RedirectFrom) > 0 && (cfg.Internal || cfg.Domain == ""):
		return nil, fmt.Errorf("%s: redirect_from needs a public domain to redirect TO", configFile)
	case len(cfg.RedirectFrom) > 0 && cfg.Path != "":
		return nil, fmt.Errorf("%s: redirect_from isn't for path-mounted apps — the gateway host owns the domain", configFile)
	case len(cfg.RedirectFrom) > 20:
		return nil, fmt.Errorf("%s: redirect_from supports at most 20 aliases (got %d)", configFile, len(cfg.RedirectFrom))
	case len(cfg.Domains) > 20:
		return nil, fmt.Errorf("%s: domain supports at most 20 hostnames (got %d)", configFile, len(cfg.Domains))
	case len(cfg.Domains) > 1 && cfg.Path != "":
		return nil, fmt.Errorf("%s: a path-mounted app takes exactly one domain — the gateway host owns it", configFile)
	}
	// every hostname this app claims — the domain list (serving) and the
	// redirect_from list (301s) — must be well-formed and mutually distinct.
	seen := map[string]bool{}
	for _, d := range cfg.Domains {
		if !domainRe.MatchString(d) {
			return nil, fmt.Errorf("%s: %q doesn't look like a domain", configFile, d)
		}
		if seen[d] {
			return nil, fmt.Errorf("%s: domain lists %q twice", configFile, d)
		}
		seen[d] = true
	}
	for _, alias := range cfg.RedirectFrom {
		switch {
		case !domainRe.MatchString(alias):
			return nil, fmt.Errorf("%s: redirect_from %q doesn't look like a domain", configFile, alias)
		case alias == cfg.Domain:
			return nil, fmt.Errorf("%s: redirect_from includes the app's own domain %q — that's a redirect loop", configFile, alias)
		case seen[alias]:
			return nil, fmt.Errorf("%s: %q is listed both as a served domain and in redirect_from", configFile, alias)
		}
		seen[alias] = true
	}
	if err := validateHeaders(configFile, cfg.Headers); err != nil {
		return nil, err
	}
	if cfg.Replicas == 0 {
		cfg.Replicas = 1
	}
	if cfg.Autoscale.on() && cfg.Autoscale.TargetCPU == 0 {
		cfg.Autoscale.TargetCPU = 70
	}
	return cfg, nil
}

// expandEnvStrict expands ${VAR}/$VAR in a config field from the process
// environment and errors if any referenced variable is unset — so a missing CI
// variable fails the deploy loudly instead of silently producing an empty
// value. A set-but-empty variable is allowed (it expands to ""). A literal "$"
// not forming a variable is preserved.
func expandEnvStrict(field, s string) (string, error) {
	if !strings.Contains(s, "$") {
		return s, nil
	}
	// os.Expand silently drops a malformed ref (`${}` or an unterminated `${`),
	// which would ship an empty value in violation of the hard-error promise —
	// reject them up front.
	if malformedRefRe.MatchString(s) {
		return "", fmt.Errorf("%s: %s has a malformed ${...} reference: %q", configFile, field, s)
	}
	var missing []string
	out := os.Expand(s, func(name string) string {
		if name == "" {
			return "$" // a lone "$" — nothing to expand
		}
		if v, ok := os.LookupEnv(name); ok {
			return v
		}
		missing = append(missing, name)
		return ""
	})
	if len(missing) > 0 {
		return "", fmt.Errorf("%s: %s references unset environment variable(s): %s", configFile, field, strings.Join(missing, ", "))
	}
	return out, nil
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
		dashIfEmpty(c.Path),
		dashIfEmpty(c.Sandbox),
		dashIfEmpty(c.Strategy),
		dashIfEmpty(c.Health.Timeout),
		boolArg(c.isStatic()),  // arg 17: static mode
		boolArg(c.spaResolved), // arg 18: SPA fallback
		encodeHeaders(c.Headers), // arg 19: user response headers (base64 "Name: value" lines)
		tlsArg(c.TLS),            // arg 20: "manual" | "dns:<provider>" | "-" (auto)
		dashIfEmpty(c.DNSTokenEnv), // arg 21: token env var override for dns: mode
		dashIfEmpty(strings.Join(c.RedirectFrom, ",")), // arg 22: alias domains that 301 here (comma-safe: commas can't appear in a domain)
		dashIfEmpty(strings.Join(c.extraDomains(), ",")), // arg 23: extra SERVED hostnames (domain list beyond the first)
	}
}

// extraDomains returns the served hostnames beyond the canonical first one.
func (c *config) extraDomains() []string {
	if len(c.Domains) > 1 {
		return c.Domains[1:]
	}
	return nil
}

// tlsArg renders the TLS mode as homeportd's positional token: "manual"
// (bring-your-own cert) and "dns:<provider>" (DNS-01) pass through; anything
// else ("", "auto") is the default ACME path.
func tlsArg(mode string) string {
	if mode == "manual" || strings.HasPrefix(mode, "dns:") {
		return mode
	}
	return "-"
}

// encodeHeaders serialises the user's response headers as sorted, tab-separated
// "glob<TAB>Name<TAB>value" records, base64-encoded into a single positional
// token ("-" when none). Sorted by (glob, name) so records for one glob are
// contiguous (homeportd groups them into one Caddy block) and deterministic.
func encodeHeaders(h map[string]map[string]string) string {
	if len(h) == 0 {
		return "-"
	}
	globs := make([]string, 0, len(h))
	for glob := range h {
		globs = append(globs, glob)
	}
	sort.Strings(globs)
	var b strings.Builder
	for _, glob := range globs {
		names := make([]string, 0, len(h[glob]))
		for name := range h[glob] {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			fmt.Fprintf(&b, "%s\t%s\t%s\n", glob, name, h[glob][name])
		}
	}
	return base64.StdEncoding.EncodeToString([]byte(b.String()))
}

// validateHeaders rejects path globs / header names / values that could break
// out of the generated Caddyfile — CRLF injection, quote/brace/backslash
// escapes, or a tab (the wire delimiter). homeport emits these verbatim.
func validateHeaders(configFile string, h map[string]map[string]string) error {
	for glob, hdrs := range h {
		if !headerGlobRe.MatchString(glob) || strings.Contains(glob, "..") {
			return fmt.Errorf(`%s: header path %q is invalid (a glob like "/*" or "/_app/immutable/*")`, configFile, glob)
		}
		for name, val := range hdrs {
			if !headerNameRe.MatchString(name) {
				return fmt.Errorf("%s: header name %q is invalid (letters, digits and - only)", configFile, name)
			}
			if !headerValueRe.MatchString(val) || strings.ContainsAny(val, "\"\\{}") {
				return fmt.Errorf(`%s: header %q has an unsafe value (one line of printable ASCII, no " \ { })`, configFile, name)
			}
		}
	}
	return nil
}

// boolArg renders a bool as homeportd's "1"/"-" positional convention.
func boolArg(b bool) string {
	if b {
		return "1"
	}
	return "-"
}

// runVarRe matches exactly the braced ${PORT}/${HOST} or the bare $PORT/$HOST
// (bare requires a word boundary, so $PORTS/$HOSTNAME are NOT treated as
// supported — they leave a stray "$" the caller rejects). Only these two are
// substituted server-side.
var runVarRe = regexp.MustCompile(`\$(\{(PORT|HOST)\}|(PORT|HOST)\b)`)

// stripRunVars removes the supported variables so a leftover "$" can be
// detected (any other $VAR is rejected).
func stripRunVars(s string) string {
	return runVarRe.ReplaceAllString(s, "")
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
