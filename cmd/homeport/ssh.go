package main

import (
	"io"
	"os"
	"os/exec"
	"strings"
)

// muxOpts multiplexes every ssh/scp over one connection: a deploy makes
// four+ round trips (register, mkdir, upload, activate) and would otherwise
// pay a full handshake + auth for each. The master persists briefly so
// consecutive commands (and back-to-back deploys) reuse it.
var muxOpts = []string{
	"-o", "ControlMaster=auto",
	"-o", "ControlPath=~/.ssh/homeport-%C",
	"-o", "ControlPersist=60s",
	// Fail fast on unreachable hosts instead of the OS's ~75s TCP timeout —
	// matters doubly for MCP tool calls, which agents sit waiting on.
	"-o", "ConnectTimeout=10",
}

// run executes a local command with the user's terminal wired through.
// stdin == nil inherits the terminal (interactive ssh prompts still work).
func run(stdin io.Reader, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	if stdin != nil {
		cmd.Stdin = stdin
	} else {
		cmd.Stdin = os.Stdin
	}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func sshRun(server, remote string) error {
	return run(nil, "ssh", append(muxOpts, server, remote)...)
}

// sshRunIn pipes data over stdin — how secrets travel: never argv, never a
// file on the far side outside homeportd's control.
func sshRunIn(server, remote, stdin string) error {
	return run(strings.NewReader(stdin), "ssh", append(muxOpts, server, remote)...)
}

// sshRunInFile streams a local file over stdin to a remote command — how the
// binary is uploaded (homeportd `upload` reads it), replacing scp so every
// privileged step goes through homeportd and a scoped CI key has one entry point.
func sshRunInFile(server, remote, path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return run(f, "ssh", append(muxOpts, server, remote)...)
}

// sshRunTTY allocates a remote tty so Ctrl-C reaches e.g. journalctl -f.
func sshRunTTY(server, remote string) error {
	return run(nil, "ssh", append(append([]string{"-t"}, muxOpts...), server, remote)...)
}

// sshOutput runs a remote command and returns its stdout (stderr passes
// through to the terminal) — for commands the CLI parses rather than shows.
func sshOutput(server, remote string) (string, error) {
	cmd := exec.Command("ssh", append(muxOpts, server, remote)...)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	return string(out), err
}
