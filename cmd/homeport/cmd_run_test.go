package main

import (
	"os/exec"
	"slices"
	"strings"
	"testing"
)

// homeport run sends the command through ssh, where the far side's shell
// parses it again: every argument must arrive exactly as given.
func TestRunArgumentsReachTheBoxAsGiven(t *testing.T) {
	args := []string{"set-plan", "team with spaces", "it's", `$HOME`, `a\b`, "line\nbreak", `"quoted"`, "", "-dash"}
	remote := runCommand(&config{App: "hpd-api"}, args)
	if !strings.HasPrefix(remote, "sudo /usr/local/bin/homeportd run hpd-api ") {
		t.Fatalf("remote %q", remote)
	}
	// what a shell makes of the part after homeportd: the arguments
	after := strings.TrimPrefix(remote, "sudo /usr/local/bin/homeportd run hpd-api ")
	got, err := exec.Command("sh", "-c", "eval set -- "+shQuote(after)+`; for a in "$@"; do printf '%s\0' "$a"; done`).Output()
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(strings.TrimSuffix(string(got), "\x00"), "\x00")
	if !slices.Equal(parts, args) {
		t.Fatalf("the box would see %q, want %q", parts, args)
	}
}

func TestRunNeedsACommand(t *testing.T) {
	if err := cmdRun(nil); err == nil {
		t.Fatal("homeport run with nothing to run")
	}
}
