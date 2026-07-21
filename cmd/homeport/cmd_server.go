package main

import (
	"fmt"
	"regexp"
	"strings"

	homeport "github.com/homeport-sh/homeport"
)

// cmdServer manages the box itself (as opposed to an app on it).
//
//	homeport server update [deploy@host]
//	homeport server plugins [add <module>... | rm <module>] [deploy@host]
//
// `update` pushes the homeportd bundled inside THIS CLI binary to the server
// via `homeportd self-update` — the post-hardening update path (root SSH is
// disabled, so re-running bootstrap isn't possible). CLI and server helper
// stay in lockstep because the script travels inside the binary.
// `plugins` swaps Caddy for an official caddyserver.com build with the named
// plugin modules baked in (nothing compiles on the box).
func cmdServer(args []string) error {
	const use = "usage: homeport server <update [deploy@host] | plugins [add <module>... | rm <module>] [deploy@host]>"
	if len(args) < 1 {
		return fmt.Errorf("%s", use)
	}
	switch args[0] {
	case "update":
		target, err := serverTarget(args[1:])
		if err != nil {
			return err
		}
		script, err := embeddedHomeportd()
		if err != nil {
			return err
		}
		step("updating homeportd on %s", target)
		if err := sshRunIn(target, "sudo /usr/local/bin/homeportd self-update", script); err != nil {
			return fmt.Errorf("self-update failed — a homeportd from before v0.1.0 lacks this command; "+
				"update those boxes via Hetzner rescue mode, or recreate them (%w)", err)
		}
		return sshRun(target, "sudo /usr/local/bin/homeportd version")
	case "plugins":
		return cmdServerPlugins(args[1:])
	default:
		return fmt.Errorf("%s", use)
	}
}

// serverTarget resolves the box to operate on: an explicit deploy@host arg
// wins, else the server from the local homeport.yaml.
func serverTarget(args []string) (string, error) {
	if len(args) > 0 {
		target := normalizeServer(args[0])
		return target, validServer(target)
	}
	cfg, err := loadConfig()
	if err != nil {
		return "", fmt.Errorf("no target given and %w", err)
	}
	return cfg.Server, nil
}

// caddyModuleRe mirrors homeportd's valid_caddy_module: a Go module repo path.
// Checked client-side too so a typo fails before any SSH round-trip.
var caddyModuleRe = regexp.MustCompile(`^[a-z0-9][a-zA-Z0-9._-]*(/[a-zA-Z0-9._-]+)+$`)

func validCaddyModule(m string) error {
	if len(m) > 200 || strings.Contains(m, "..") || !caddyModuleRe.MatchString(m) {
		return fmt.Errorf("invalid plugin module %q — expected a repo path like github.com/caddy-dns/cloudflare", m)
	}
	return nil
}

func cmdServerPlugins(args []string) error {
	// an optional trailing deploy@host applies to any form
	host := []string{}
	if n := len(args); n > 0 && strings.Contains(args[n-1], "@") {
		host, args = args[n-1:], args[:n-1]
	}
	target, err := serverTarget(host)
	if err != nil {
		return err
	}
	if len(args) == 0 { // list
		return sshRun(target, "sudo /usr/local/bin/homeportd caddy-plugin-list")
	}
	verb, modules := args[0], args[1:]
	if (verb != "add" && verb != "rm") || len(modules) == 0 || (verb == "rm" && len(modules) != 1) {
		return fmt.Errorf("usage: homeport server plugins [add <module>... | rm <module>] [deploy@host]")
	}
	for _, m := range modules {
		if err := validCaddyModule(m); err != nil {
			return err
		}
	}
	return sshRun(target, "sudo /usr/local/bin/homeportd caddy-plugin-"+verb+" "+strings.Join(modules, " "))
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
