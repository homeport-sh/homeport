package main

import (
	"fmt"
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

	case "push":
		file := ""
		if len(args) > 1 {
			file = args[1]
		} else {
			for _, f := range []string{".env.production", ".env"} {
				if _, err := os.Stat(f); err == nil {
					file = f
					break
				}
			}
		}
		if file == "" {
			return fmt.Errorf("usage: homeport secrets push [env-file]   (no .env.production or .env found)")
		}
		data, err := os.ReadFile(file)
		if err != nil {
			return err
		}
		step("pushing %s to %s", file, cfg.App)
		// register first so secrets can be seeded before the first deploy
		if err := cfg.register(); err != nil {
			return fmt.Errorf("could not register %s: %w", cfg.App, err)
		}
		return sshRunIn(cfg.Server, cfg.homeportd("env", cfg.App), string(data))

	case "list":
		return sshRun(cfg.Server, cfg.homeportd("env-list", cfg.App))

	default:
		return fmt.Errorf("usage: homeport secrets <set KEY=value ... | push [env-file] | list>")
	}
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
