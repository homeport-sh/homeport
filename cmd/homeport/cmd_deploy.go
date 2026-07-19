package main

import (
	"fmt"
	"os"
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
