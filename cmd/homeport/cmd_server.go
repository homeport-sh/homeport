package main

import (
	"fmt"
	"strings"

	homeport "github.com/homeport-sh/homeport"
)

// cmdServer manages the box itself (as opposed to an app on it).
//
//	homeport server update [deploy@host]
//
// pushes the homeportd bundled inside THIS CLI binary to the server via
// `homeportd self-update` — the post-hardening update path (root SSH is
// disabled, so re-running bootstrap isn't possible). CLI and server helper
// stay in lockstep because the script travels inside the binary.
func cmdServer(args []string) error {
	if len(args) < 1 || args[0] != "update" {
		return fmt.Errorf("usage: homeport server update [deploy@host]")
	}

	target := ""
	if len(args) > 1 {
		target = args[1]
		if !strings.Contains(target, "@") {
			return fmt.Errorf("target should look like deploy@1.2.3.4 (got %q)", target)
		}
	} else {
		cfg, err := loadConfig()
		if err != nil {
			return fmt.Errorf("no target given and %w", err)
		}
		target = cfg.Server
	}

	script, err := embeddedHomeportd()
	if err != nil {
		return err
	}

	step("updating homeportd on %s", target)
	if err := sshRunIn(target, "sudo /usr/local/bin/homeportd self-update", script); err != nil {
		return fmt.Errorf("self-update failed — a homeportd from before v0.2.0 lacks this command; "+
			"update those boxes via Hetzner rescue mode, or recreate them (%w)", err)
	}
	return sshRun(target, "sudo /usr/local/bin/homeportd version")
}

// embeddedHomeportd extracts the homeportd script from the bundled
// bootstrap between its heredoc markers.
func embeddedHomeportd() (string, error) {
	const startMarker = "<<'HOMEPORTD_SCRIPT'\n"
	const endMarker = "\nHOMEPORTD_SCRIPT\n"
	s := homeport.BootstrapScript
	start := strings.Index(s, startMarker)
	if start < 0 {
		return "", fmt.Errorf("bundled bootstrap has no embedded homeportd (build corrupt?)")
	}
	s = s[start+len(startMarker):]
	end := strings.Index(s, endMarker)
	if end < 0 {
		return "", fmt.Errorf("bundled homeportd is unterminated (build corrupt?)")
	}
	return s[:end] + "\n", nil
}
