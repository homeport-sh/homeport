package main

import (
	"errors"
	"fmt"

	"github.com/homeport-sh/homeport/artifact"
)

// checkLinuxBinary verifies the artifact is a Linux (ELF) executable before
// it travels to the server — catching the classic mistake of deploying the
// macOS binary you just built on your laptop. Returns the ELF architecture.
//
// The inspection itself lives in the artifact package so that a control plane
// deploying on someone's behalf refuses exactly what the CLI refuses. What
// stays here is the advice, which only makes sense at a terminal.
func checkLinuxBinary(path string) (string, error) {
	arch, err := artifact.CheckFile(path)
	if errors.Is(err, artifact.ErrMachO) {
		return "", fmt.Errorf("%w; see the cross-compile note in %s", err, configFile)
	}
	return arch, err
}
