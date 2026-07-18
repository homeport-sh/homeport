package main

import (
	"fmt"
	"strings"
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
		if cfg, err := loadConfig(); err == nil {
			target = cfg.Server
		} else {
			target = lastServer()
		}
	}
	if target == "" {
		return fmt.Errorf("no server given and none remembered — usage: homeport apps <ip|user@host>")
	}
	target = normalizeServer(target)
	if !strings.Contains(target, "@") {
		return fmt.Errorf("server should look like deploy@1.2.3.4 (got %q)", target)
	}

	remote := "sudo /usr/local/bin/homeportd status"
	if jsonOut {
		remote += " --json"
	}
	return sshRun(target, remote)
}
