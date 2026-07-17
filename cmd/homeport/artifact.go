package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"
)

// checkLinuxBinary verifies the artifact is a Linux (ELF) executable before
// it travels to the server — catching the classic mistake of deploying the
// macOS binary you just built on your laptop. Returns the ELF architecture.
func checkLinuxBinary(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	head := make([]byte, 20)
	if _, err := io.ReadFull(f, head); err != nil {
		return "", fmt.Errorf("%s is too small to be an executable", path)
	}

	if !(head[0] == 0x7f && head[1] == 'E' && head[2] == 'L' && head[3] == 'F') {
		// Mach-O magic (0xcffaedfe LE / 0xfeedfacf BE) → say it plainly.
		if (head[0] == 0xcf || head[0] == 0xce) && head[1] == 0xfa && head[2] == 0xed && head[3] == 0xfe ||
			head[0] == 0xfe && head[1] == 0xed && head[2] == 0xfa {
			return "", fmt.Errorf("%s is a macOS binary — the server needs a Linux build; see the cross-compile note in %s", path, configFile)
		}
		return "", fmt.Errorf("%s is not a Linux (ELF) executable", path)
	}

	switch binary.LittleEndian.Uint16(head[18:20]) {
	case 0x3e:
		return "x86-64", nil
	case 0xb7:
		return "arm64", nil
	default:
		return fmt.Sprintf("machine 0x%x", binary.LittleEndian.Uint16(head[18:20])), nil
	}
}
