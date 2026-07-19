package main

import (
	"fmt"
	"strings"

	homeport "github.com/homeport-sh/homeport"
)

func cmdBootstrap(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: homeport bootstrap <server-ip>   (a fresh Ubuntu box; user@ip to override the root default)")
	}
	target := args[0]
	if !strings.Contains(target, "@") {
		// fresh boxes are reached as root; the hardening then closes that door
		target = "root@" + target
	}
	if err := validServer(target); err != nil {
		return err
	}
	user := target[:strings.Index(target, "@")]
	host := target[strings.Index(target, "@")+1:]

	// Cloud images without root SSH (AWS/DO: ubuntu@, admin@) still work —
	// escalate through their passwordless sudo instead.
	remote := "bash -s"
	if user != "root" {
		remote = "sudo -n bash -s"
	}

	step("bootstrapping %s (hardening + Caddy + homeportd)", target)
	if err := run(strings.NewReader(homeport.BootstrapScript), "ssh", target, remote); err != nil {
		return fmt.Errorf("bootstrap failed: %w\n"+
			"  - already bootstrapped this box? root login is disabled after hardening by design —\n"+
			"    updates go through `homeport server update`, apps through `homeport deploy`\n"+
			"  - image without root SSH (AWS, DO)? target its admin user: homeport bootstrap ubuntu@%s", err, host)
	}
	saveLastServer("deploy@" + host)
	step("done — root SSH login is now disabled; from now on use deploy@%s", host)
	return nil
}
