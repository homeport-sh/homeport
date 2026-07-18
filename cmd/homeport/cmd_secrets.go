package main

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
)

var envLineRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)

func cmdSecrets(args []string) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	if len(args) == 0 {
		return fmt.Errorf("usage: homeport secrets <set KEY=value ... | push [env-file] | list>")
	}

	switch args[0] {
	case "set":
		pairs := args[1:]
		if len(pairs) == 0 {
			return fmt.Errorf("usage: homeport secrets set KEY=value [KEY=value ...]")
		}
		for _, p := range pairs {
			if !envLineRe.MatchString(p) {
				return fmt.Errorf("expected KEY=value, got %q", p)
			}
		}
		// register first so secrets can be seeded before the first deploy
		if err := cfg.register(); err != nil {
			return fmt.Errorf("could not register %s: %w", cfg.App, err)
		}
		// values travel over ssh stdin — never argv, never shell history
		return sshRunIn(cfg.Server, cfg.homeportd("env", cfg.App), strings.Join(pairs, "\n")+"\n")

	case "push", "sync":
		data, src, err := readEnvArg(args)
		if err != nil {
			return err
		}
		verb := "env" // merge
		if args[0] == "sync" {
			verb = "env-sync" // declarative full replace
		}
		step("%sing %s to %s", args[0], src, cfg.App)
		// register first so secrets can be seeded before the first deploy
		if err := cfg.register(); err != nil {
			return fmt.Errorf("could not register %s: %w", cfg.App, err)
		}
		return sshRunIn(cfg.Server, cfg.homeportd(verb, cfg.App), data)

	case "rm", "unset":
		keys := args[1:]
		if len(keys) == 0 {
			return fmt.Errorf("usage: homeport secrets rm KEY [KEY ...]")
		}
		for _, k := range keys {
			if !keyRe.MatchString(k) {
				return fmt.Errorf("invalid key %q", k)
			}
		}
		return sshRun(cfg.Server, cfg.homeportd(append([]string{"env-rm", cfg.App}, keys...)...))

	case "list":
		return sshRun(cfg.Server, cfg.homeportd("env-list", cfg.App))

	default:
		return fmt.Errorf("usage: homeport secrets <set K=V… | rm KEY… | push [file|-] | sync [file|-] | list>")
	}
}

var keyRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// readEnvArg resolves the env source for push/sync: "-" (or piped stdin) reads
// stdin; a path reads that file; otherwise it auto-detects .env.production/.env.
// Returns the content and a label for messages.
func readEnvArg(args []string) (data, src string, err error) {
	arg := ""
	if len(args) > 1 {
		arg = args[1]
	}
	if arg == "-" {
		b, e := io.ReadAll(os.Stdin)
		return string(b), "stdin", e
	}
	file := arg
	if file == "" {
		// no arg: piped stdin if present, else auto-detect a dotenv file
		if fi, _ := os.Stdin.Stat(); fi != nil && fi.Mode()&os.ModeCharDevice == 0 {
			b, e := io.ReadAll(os.Stdin)
			return string(b), "stdin", e
		}
		for _, f := range []string{".env.production", ".env"} {
			if _, e := os.Stat(f); e == nil {
				file = f
				break
			}
		}
		if file == "" {
			return "", "", fmt.Errorf("no env file given and no .env.production/.env found (use - for stdin)")
		}
	}
	b, e := os.ReadFile(file)
	return string(b), file, e
}

func cmdStatus(args []string) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	homeportdArgs := []string{"status", cfg.App}
	if hasFlag(args, "--json") {
		homeportdArgs = append(homeportdArgs, "--json")
	}
	return sshRun(cfg.Server, cfg.homeportd(homeportdArgs...))
}

func cmdLogs(args []string) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	homeportdArgs := []string{"logs", cfg.App}
	follow := false
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-f":
			follow = true
			homeportdArgs = append(homeportdArgs, "-f")
		case "-n":
			if i+1 >= len(args) || !regexp.MustCompile(`^\d+$`).MatchString(args[i+1]) {
				return fmt.Errorf("-n needs a number")
			}
			homeportdArgs = append(homeportdArgs, "-n", args[i+1])
			i++
		default:
			return fmt.Errorf("unknown logs option %q", args[i])
		}
	}
	if follow {
		// tty so Ctrl-C reaches journalctl -f on the far side
		return sshRunTTY(cfg.Server, cfg.homeportd(homeportdArgs...))
	}
	return sshRun(cfg.Server, cfg.homeportd(homeportdArgs...))
}
