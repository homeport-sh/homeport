package main

import (
	"fmt"
	"strings"

	homeport "github.com/homeport-sh/homeport"
)

func cmdBootstrap(args []string) error {
	if len(args) != 1 || !strings.Contains(args[0], "@") {
		return fmt.Errorf("usage: homeport bootstrap root@<server-ip>   (a fresh Ubuntu box)")
	}
	target := args[0]
	step("bootstrapping %s (hardening + Caddy + homeportd)", target)
	if err := run(strings.NewReader(homeport.BootstrapScript), "ssh", target, "bash -s"); err != nil {
		return fmt.Errorf("bootstrap failed: %w", err)
	}
	host := target[strings.Index(target, "@")+1:]
	step("done — root SSH login is now disabled; from now on use deploy@%s", host)
	return nil
}
