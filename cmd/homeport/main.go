// Command homeport deploys single-binary web apps — Go, Rust, bun --compile,
// anything that ships as one executable — to a plain VPS over SSH.
//
// No agent, no registry, no Docker. The server side is set up once by
// `homeport bootstrap`, which hardens a fresh Ubuntu box and installs homeportd,
// the root-side helper this CLI drives as the unprivileged deploy user.
// A future web UI is just another client of the same homeportd contract.
package main

import (
	"fmt"
	"os"
)

const version = "0.1.0"

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		usage()
		return
	}
	cmd, rest := args[0], args[1:]
	var err error
	switch cmd {
	case "init":
		err = cmdInit(rest)
	case "bootstrap":
		err = cmdBootstrap(rest)
	case "deploy":
		err = cmdDeploy(rest)
	case "rollback":
		err = cmdRollback(rest)
	case "secrets":
		err = cmdSecrets(rest)
	case "status":
		err = cmdStatus(rest)
	case "logs":
		err = cmdLogs(rest)
	case "mcp":
		err = cmdMCP(rest)
	case "server":
		err = cmdServer(rest)
	case "ci":
		err = cmdCI(rest)
	case "version", "-v", "--version":
		fmt.Println("homeport", version)
	case "help", "-h", "--help":
		usage()
	default:
		err = fmt.Errorf("unknown command %q (try: homeport help)", cmd)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "\x1b[1;31merror:\x1b[0m %v\n", err)
		os.Exit(1)
	}
}

func step(format string, a ...any) {
	fmt.Printf("\x1b[1;32m==>\x1b[0m "+format+"\n", a...)
}

func hasFlag(args []string, flag string) bool {
	for _, a := range args {
		if a == flag {
			return true
		}
	}
	return false
}

func usage() {
	fmt.Print(`homeport — deploy single-binary web apps to your own VPS

setup (once per server):
  homeport bootstrap root@<ip>     harden a fresh Ubuntu VPS, install Caddy + homeportd

setup (once per project):
  homeport init                    write homeport.yaml (app, server, domain, build)
  homeport ci setup github         generate a CI deploy key + GitHub Actions workflow

everyday:
  homeport deploy [--no-build]     build → upload → health-checked activate (auto-reverts)
  homeport rollback [release]      instant rollback to the previous (or given) release
  homeport secrets set K=V ...     set env values (sent over ssh stdin, never argv)
  homeport secrets push [file]     upload a whole .env file
  homeport secrets list            list env keys (values never leave the server)
  homeport status [--json]         app state, live release, available releases
  homeport logs [-f] [-n N]        app logs (journald)
  homeport mcp                  serve the CLI as MCP tools (stdio) for AI agents
  homeport server update        push this CLI's bundled homeportd to the box

Your binary's contract: listen on $PORT (bind $HOST, 127.0.0.1); persist
only under $STATE_DIR. Caddy terminates TLS in front of it.
`)
}
