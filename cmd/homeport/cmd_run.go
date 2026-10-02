package main

import (
	"errors"
	"strings"
)

// cmdRun runs the app's current release once on its server, as the app,
// with its environment: an operator's one-off command (an admin command, a
// manual migration). Its output streams back; its exit status is run's.
//
//	homeport run [--] <args…>
func cmdRun(args []string) error {
	if len(args) > 0 && args[0] == "--" {
		args = args[1:]
	}
	if len(args) == 0 {
		return errors.New("usage: homeport run [--] <args…>   (runs the app's binary once, with its env)")
	}
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	return sshRun(cfg.Server, runCommand(cfg, args))
}

// runCommand is the remote command line: homeportd's run, each argument
// quoted, since the far side's shell parses the line again.
func runCommand(cfg *config, args []string) string {
	quoted := make([]string, len(args))
	for i, a := range args {
		quoted[i] = shQuote(a)
	}
	return cfg.homeportd(append([]string{"run", cfg.App}, quoted...)...)
}

// shQuote makes s one shell word, exactly: single quotes, and each ' as '\”.
func shQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
