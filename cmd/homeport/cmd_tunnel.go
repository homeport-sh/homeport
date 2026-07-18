package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// cmdTunnel forwards a local port to an app's loopback port on the server,
// so internal (or any) apps are reachable from your laptop without exposing
// them publicly. This is the access path for `internal: true` apps —
// nothing on 80/443, just an SSH-forwarded loopback socket.
//
//	homeport tunnel [localPort]
func cmdTunnel(args []string) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	// Ask homeportd where the app listens (its loopback port).
	out, err := sshOutput(cfg.Server, cfg.homeportd("status", cfg.App, "--json"))
	if err != nil {
		return fmt.Errorf("could not read app status from %s: %w", cfg.Server, err)
	}
	var st struct {
		Port     int    `json:"port"`
		AppPort  int    `json:"app_port"`
		State    string `json:"state"`
		Internal bool   `json:"internal"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &st); err != nil {
		return fmt.Errorf("unexpected status output (is homeportd up to date?): %w", err)
	}
	// app_port (0.6.1+) is the port that actually reaches the app — for
	// replica apps nothing binds the public port (Caddy talks straight to
	// the instances). Older homeportd omits it; fall back to the public port.
	if st.AppPort != 0 {
		st.Port = st.AppPort
	}
	if st.Port == 0 {
		return fmt.Errorf("app %q has no port yet — deploy it first", cfg.App)
	}

	// Default the local port to the app's port; let the user override to
	// avoid clashes when tunneling several apps at once.
	localPort := st.Port
	if len(args) > 0 {
		p, err := strconv.Atoi(args[0])
		if err != nil || p < 1 || p > 65535 {
			return fmt.Errorf("invalid local port %q", args[0])
		}
		localPort = p
	}

	fwd := fmt.Sprintf("%d:127.0.0.1:%d", localPort, st.Port)
	step("tunneling %s → http://localhost:%d  (Ctrl-C to close)", cfg.App, localPort)

	// -N: no remote command, just forward. Inherit stdio so Ctrl-C ends it.
	sshArgs := append([]string{"-N", "-L", fwd}, cfg.Server)
	c := exec.Command("ssh", sshArgs...)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	return c.Run()
}
