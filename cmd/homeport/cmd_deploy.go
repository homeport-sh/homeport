package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

func cmdDeploy(args []string) error {
	// reject typo'd flags — a silently-ignored --no-buld would ship a full build
	for _, a := range args {
		if a != "--no-build" && a != "--no-artifact-check" {
			return fmt.Errorf("unknown option %q (deploy accepts --no-build, --no-artifact-check)", a)
		}
	}
	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	if cfg.isStatic() {
		return deployStatic(cfg, args)
	}

	if !hasFlag(args, "--no-build") {
		step("building: %s", cfg.Build.Command)
		if err := run(nil, "sh", "-c", cfg.Build.Command); err != nil {
			return fmt.Errorf("build failed: %w", err)
		}
	}

	st, err := os.Stat(cfg.Build.Artifact)
	if err != nil {
		return fmt.Errorf("no artifact at %s — did the build produce the binary?", cfg.Build.Artifact)
	}
	arch := "unchecked"
	if !hasFlag(args, "--no-artifact-check") {
		if arch, err = checkLinuxBinary(cfg.Build.Artifact); err != nil {
			return fmt.Errorf("%w (--no-artifact-check to override)", err)
		}
	}

	id := releaseID()

	step("registering %s on %s", cfg.App, cfg.Server)
	if err := cfg.register(); err != nil {
		return fmt.Errorf("app registration failed — did you run `homeport bootstrap` on this server? (%w)", err)
	}

	step("uploading %s (%.1f MB, linux %s) as release %s", cfg.Build.Artifact, float64(st.Size())/1024/1024, arch, id)
	// stream the binary through homeportd's `upload` verb (not scp), so every
	// privileged step is one homeportd call — and a scoped CI key has one gate.
	if err := sshRunInFile(cfg.Server, cfg.homeportd("upload", cfg.App, id), cfg.Build.Artifact); err != nil {
		return fmt.Errorf("upload failed: %w", err)
	}

	step("activating (restart + health check, auto-reverts on failure)")
	if err := sshRun(cfg.Server, cfg.homeportd("activate", cfg.App, id)); err != nil {
		return fmt.Errorf("activation failed: %w", err)
	}
	if cfg.Internal {
		step("deployed → internal (reach it with `homeport tunnel`)")
	} else {
		step("deployed → https://%s%s", cfg.Domain, cfg.Path)
	}
	return nil
}

func cmdRollback(args []string) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	homeportdArgs := []string{"rollback", cfg.App}
	if len(args) > 0 {
		if !releaseRe.MatchString(args[0]) {
			return fmt.Errorf("invalid release id %q", args[0])
		}
		homeportdArgs = append(homeportdArgs, args[0])
	}
	return sshRun(cfg.Server, cfg.homeportd(homeportdArgs...))
}

// cmdRemove deletes an app and everything it owns — releases, env, systemd
// units, and its user. Destructive and irreversible, so it confirms by having
// you retype the app name (unless --yes). With no app argument it removes the
// app defined by the local homeport.yaml; you can also name an app explicitly
// (handy from outside its project dir) and point it at a box with deploy@host.
//
//	homeport remove [app] [deploy@host] [--yes]
func cmdRemove(args []string) error {
	yes := hasFlag(args, "--yes")
	args = withoutFlag(args, "--yes")

	var explicitHost string
	if n := len(args); n > 0 && strings.Contains(args[n-1], "@") {
		explicitHost, args = args[n-1], args[:n-1]
	}

	var app, server string
	switch len(args) {
	case 0: // fall back to the local project config
		cfg, err := loadConfig()
		if err != nil {
			return err
		}
		app, server = cfg.App, cfg.Server
		if explicitHost != "" {
			server = normalizeServer(explicitHost)
		}
	case 1: // explicit app name
		app = args[0]
		if !appRe.MatchString(app) {
			return fmt.Errorf("invalid app name %q (lowercase letters, digits, dashes)", app)
		}
		if explicitHost != "" {
			server = normalizeServer(explicitHost)
		} else {
			cfg, err := loadConfig()
			if err != nil {
				return fmt.Errorf("removing %q needs a server — pass deploy@host, or run inside its project dir (%w)", app, err)
			}
			server = cfg.Server
		}
	default:
		return fmt.Errorf("usage: homeport remove [app] [deploy@host] [--yes]")
	}
	if err := validServer(server); err != nil {
		return err
	}

	if !yes {
		fmt.Fprintf(os.Stderr, "This permanently removes app %q and all its releases, env, and user on %s.\nType the app name to confirm: ", app, server)
		line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		if strings.TrimSpace(line) != app {
			return fmt.Errorf("aborted — the name did not match")
		}
	}
	return sshRun(server, "sudo /usr/local/bin/homeportd remove "+app+" --yes")
}
