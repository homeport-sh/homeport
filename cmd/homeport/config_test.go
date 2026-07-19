package main

import (
	"strings"
	"testing"
)

// A minimal valid config the validation cases can start from.
const baseYAML = "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\n"

func TestParseConfigValid(t *testing.T) {
	cfg, err := parseConfig([]byte(baseYAML))
	if err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
	if cfg.App != "web" || cfg.Domain != "web.example.com" {
		t.Fatalf("unexpected parse: %+v", cfg)
	}
	if cfg.Replicas != 1 {
		t.Errorf("replicas should default to 1, got %d", cfg.Replicas)
	}
	if cfg.Health.Path != "/" {
		t.Errorf("health.path should default to /, got %q", cfg.Health.Path)
	}
	if cfg.Internal {
		t.Errorf("app with a domain must not be internal")
	}
}

func TestParseConfigInternalNormalization(t *testing.T) {
	cfg, err := parseConfig([]byte("app: worker\nserver: deploy@1.2.3.4\ninternal: true\n"))
	if err != nil {
		t.Fatalf("internal app rejected: %v", err)
	}
	if !cfg.Internal || cfg.Domain != "" {
		t.Errorf("expected internal with empty domain, got internal=%v domain=%q", cfg.Internal, cfg.Domain)
	}
}

// Each case is a config that must be REJECTED, with a substring the error
// should mention. These are the regressions unit tests exist to catch.
func TestParseConfigRejects(t *testing.T) {
	cases := []struct {
		name string
		yaml string
		want string
	}{
		{"bad app name", "app: Web_1\nserver: deploy@1.2.3.4\ndomain: web.example.com\n", "app"},
		{"empty server", "app: web\nserver: \"\"\ndomain: web.example.com\n", "server"},
		{"domain and internal", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\ninternal: true\n", "either a domain"},
		{"bad domain", "app: web\nserver: deploy@1.2.3.4\ndomain: 'not a domain'\n", "domain"},
		{"path without domain", "app: web\nserver: deploy@1.2.3.4\ninternal: true\npath: /api\n", "path"},
		{"bad path", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\npath: api\n", "path"},
		{"bad health timeout", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nhealth:\n  timeout: 30\n", "health.timeout"},
		{"bad memory", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nresources:\n  memory: 512\n", "memory"},
		{"bad cpu", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nresources:\n  cpu: 1.5\n", "cpu"},
		{"replicas too many", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nreplicas: 99\n", "replicas"},
		{"replicas and idle", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nreplicas: 3\nidle: true\n", "mutually exclusive"},
		{"autoscale and replicas", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nreplicas: 3\nautoscale:\n  min: 1\n  max: 4\n", "either replicas"},
		{"autoscale bad bounds", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nautoscale:\n  min: 5\n  max: 2\n", "min <= max"},
		{"idle_timeout without idle", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nidle_timeout: 5m\n", "idle is not true"},
		{"run extra var", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nrun: serve --port $PORT --db $DBHOST\n", "only reference"},
		{"multiline release", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nrelease: \"a\\nb\"\n", "single line"},
		{"bad sandbox", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nsandbox: loose\n", "sandbox"},
		{"bad strategy", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nstrategy: canary\n", "strategy"},
		// review fixes:
		{"server ssh-option injection", "app: web\nserver: \"-oProxyCommand=x@host\"\ndomain: web.example.com\n", "server"},
		{"server leading dash", "app: web\nserver: -evil@host\ndomain: web.example.com\n", "server"},
		{"run non-PORT/HOST var", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nrun: serve $PORTS\n", "only reference"},
		{"run $DBHOST var", "app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nrun: serve --db $DBHOST\n", "only reference"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := parseConfig([]byte(c.yaml))
			if err == nil {
				t.Fatalf("expected rejection, got none")
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("error %q should mention %q", err.Error(), c.want)
			}
		})
	}
}

func TestParseConfigNormalizesBareServer(t *testing.T) {
	cfg, err := parseConfig([]byte("app: web\nserver: 1.2.3.4\ndomain: web.example.com\n"))
	if err != nil {
		t.Fatalf("bare host server rejected: %v", err)
	}
	if cfg.Server != "deploy@1.2.3.4" {
		t.Errorf("bare host should default to deploy@, got %q", cfg.Server)
	}
}

func TestParseConfigAccepts(t *testing.T) {
	ok := []string{
		"app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nreplicas: 3\n",
		"app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nautoscale:\n  min: 1\n  max: 4\n",
		"app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nidle: true\nidle_timeout: 5m\n",
		"app: geo\nserver: deploy@1.2.3.4\ndomain: api.example.com\npath: /geo-api\n",
		"app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nrun: serve --port $PORT --host $HOST\n",
		"app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nrun: serve --port ${PORT} --host ${HOST}\n",
		"app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nsandbox: relaxed\nstrategy: recreate\n",
		"app: web\nserver: deploy@1.2.3.4\ndomain: web.example.com\nhealth:\n  timeout: 90s\n",
		"app: worker\nserver: 1.2.3.4\ninternal: true\n", // bare host normalizes, internal ok
	}
	for i, y := range ok {
		if _, err := parseConfig([]byte(y)); err != nil {
			t.Errorf("case %d should be valid, got: %v", i, err)
		}
	}
}

func TestExpandEnvStrict(t *testing.T) {
	t.Setenv("DEPLOY_HOST", "203.0.113.9")
	t.Setenv("EMPTY", "")

	// referenced-and-set expands
	if got, err := expandEnvStrict("server", "deploy@${DEPLOY_HOST}"); err != nil || got != "deploy@203.0.113.9" {
		t.Errorf("expand set var: got %q err %v", got, err)
	}
	// set-but-empty is allowed and expands to empty
	if got, err := expandEnvStrict("domain", "${EMPTY}"); err != nil || got != "" {
		t.Errorf("empty var should expand to empty: got %q err %v", got, err)
	}
	// unset is a hard error naming the field and variable
	_, err := expandEnvStrict("domain", "${NOT_SET_XYZ}")
	if err == nil || !strings.Contains(err.Error(), "NOT_SET_XYZ") || !strings.Contains(err.Error(), "domain") {
		t.Errorf("unset var should hard-error naming field+var, got %v", err)
	}
	// no $ short-circuits
	if got, _ := expandEnvStrict("app", "web-prod"); got != "web-prod" {
		t.Errorf("literal passthrough failed: %q", got)
	}
	// malformed refs are a hard error, not silently deleted (os.Expand drops them)
	for _, bad := range []string{"a${}b", "web-${ENV", "${}"} {
		if _, err := expandEnvStrict("domain", bad); err == nil {
			t.Errorf("malformed ref %q should error, got nil", bad)
		}
	}
}

func TestSecretsValueRejectsNewline(t *testing.T) {
	// a set-value with an embedded newline would smuggle extra KEY=value lines
	if envLineRe.MatchString("A=b\nEVIL=x") {
		t.Errorf("envLineRe must reject a value containing a newline")
	}
	if !envLineRe.MatchString("A=b-c_d.e/f") {
		t.Errorf("envLineRe must accept a normal single-line value")
	}
}

func TestParseConfigEnvInterpolation(t *testing.T) {
	t.Setenv("ENV", "prod")
	t.Setenv("DEPLOY_HOST", "203.0.113.9")
	t.Setenv("DOMAIN", "web.example.com")
	cfg, err := parseConfig([]byte("app: web-${ENV}\nserver: deploy@${DEPLOY_HOST}\ndomain: ${DOMAIN}\nrun: serve --port $PORT\n"))
	if err != nil {
		t.Fatalf("interpolated config rejected: %v", err)
	}
	if cfg.App != "web-prod" || cfg.Server != "deploy@203.0.113.9" || cfg.Domain != "web.example.com" {
		t.Errorf("interpolation wrong: %+v", cfg)
	}
	// run: must NOT be expanded — $PORT is homeport's own server-side var
	if !strings.Contains(cfg.Run, "$PORT") {
		t.Errorf("run should keep literal $PORT, got %q", cfg.Run)
	}
}

func TestAddArgsPositions(t *testing.T) {
	cfg := &config{
		App: "web", Domain: "web.example.com",
		Health:    healthConfig{Path: "/healthz", Timeout: "60s"},
		Replicas:  1,
		Run:       "serve --port $PORT",
		Sandbox:   "relaxed",
		Strategy:  "recreate",
		Resources: resourcesConfig{Memory: "512M"},
	}
	args := cfg.addArgs()
	// add <app> <domain> <health> <mem> <cpu> <idle> <timeout> <replicas>
	//     <autoscale> <run> <release> <post> <path> <sandbox> <strategy> <health-timeout>
	if args[0] != "add" || args[1] != "web" || args[2] != "web.example.com" || args[3] != "/healthz" {
		t.Fatalf("leading args wrong: %v", args[:4])
	}
	if args[4] != "512M" {
		t.Errorf("memory should be arg 4, got %q", args[4])
	}
	if args[len(args)-1] != "60s" {
		t.Errorf("health timeout should be last arg, got %q", args[len(args)-1])
	}
	if args[len(args)-2] != "recreate" {
		t.Errorf("strategy should be 2nd-to-last, got %q", args[len(args)-2])
	}
	if args[len(args)-3] != "relaxed" {
		t.Errorf("sandbox should be 3rd-to-last, got %q", args[len(args)-3])
	}
	// unset optional fields render as "-"
	if args[5] != "-" { // cpu
		t.Errorf("unset cpu should be '-', got %q", args[5])
	}
}

func TestDashIfEmpty(t *testing.T) {
	if dashIfEmpty("") != "-" || dashIfEmpty("x") != "x" {
		t.Errorf("dashIfEmpty wrong")
	}
}
