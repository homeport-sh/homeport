package main

import (
	"fmt"
	"os"
)

func cmdDeploy(args []string) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
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
	dir := fmt.Sprintf("/opt/homeport/%s/releases/%s", cfg.App, id)

	// homeportd add takes positional <app> <domain> <health> <mem> <cpu>
	// <idle> <idle_timeout>; "-" is the unset placeholder (empty domain =
	// internal, idle "true" = scale-to-zero).
	domain := dashIfEmpty(cfg.Domain)
	mem := dashIfEmpty(cfg.Resources.Memory)
	cpu := dashIfEmpty(cfg.Resources.CPU)
	idle := "-"
	if cfg.Idle {
		idle = "true"
	}
	idleTimeout := dashIfEmpty(cfg.IdleTimeout)
	step("registering %s on %s", cfg.App, cfg.Server)
	if err := sshRun(cfg.Server, cfg.homeportd("add", cfg.App, domain, cfg.Health.Path, mem, cpu, idle, idleTimeout)); err != nil {
		return fmt.Errorf("app registration failed — did you run `homeport bootstrap` on this server? (%w)", err)
	}

	step("uploading %s (%.1f MB, linux %s) as release %s", cfg.Build.Artifact, float64(st.Size())/1024/1024, arch, id)
	if err := sshRun(cfg.Server, "mkdir -p "+dir); err != nil {
		return fmt.Errorf("could not create release dir: %w", err)
	}
	if err := scpFile(cfg.Build.Artifact, cfg.Server+":"+dir+"/bin"); err != nil {
		return fmt.Errorf("upload failed: %w", err)
	}

	step("activating (restart + health check, auto-reverts on failure)")
	if err := sshRun(cfg.Server, cfg.homeportd("activate", cfg.App, id)); err != nil {
		return fmt.Errorf("activation failed: %w", err)
	}
	step("deployed → https://%s", cfg.Domain)
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
