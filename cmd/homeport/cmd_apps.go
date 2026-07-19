package main

import (
	"fmt"
	"os"
)

// cmdApps shows every app on a server — the fleet view. Unlike the other
// commands it needs no homeport.yaml: it's a question about a box, not a
// project. Target resolution: explicit arg > the project's server (if a
// homeport.yaml happens to be here) > the remembered last server.
//
//	homeport apps [server] [--json]
func cmdApps(args []string) error {
	target := ""
	jsonOut := false
	for _, a := range args {
		switch {
		case a == "--json":
			jsonOut = true
		case target == "":
			target = a
		default:
			return fmt.Errorf("usage: homeport apps [server] [--json]")
		}
	}

	if target == "" {
		// a homeport.yaml here → use its server, and a PARSE error is a real
		// error (don't silently target the remembered — possibly wrong — box).
		// No homeport.yaml → fall back to the last server we talked to.
		if _, statErr := os.Stat(configFile); statErr == nil {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			target = cfg.Server
		} else {
			target = lastServer()
		}
	}
	if target == "" {
		return fmt.Errorf("no server given and none remembered — usage: homeport apps <ip|user@host>")
	}
	target = normalizeServer(target)
	if err := validServer(target); err != nil {
		return err
	}

	remote := "sudo /usr/local/bin/homeportd status"
	if jsonOut {
		remote += " --json"
	}
	return sshRun(target, remote)
}
