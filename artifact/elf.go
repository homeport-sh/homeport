// Package artifact inspects a compiled binary before it travels to a server.
//
// It is a separate package so that anything driving a homeport deploy — the
// CLI, or a control plane doing it on someone's behalf — validates artifacts
// the same way. Two implementations of "is this the right kind of binary"
// would be two implementations to keep in step, and the one that drifted would
// be the one running on somebody else's hardware.
package artifact

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
)

// The architectures homeport can run, named as the rest of the tooling names
// them.
const (
	ArchAMD64 = "x86-64"
	ArchARM64 = "arm64"
)

// Why an artifact was refused. These are sentinels so a caller can tell the
// interesting case — a macOS binary, which is a mistake with an obvious fix —
// apart from the merely malformed.
var (
	ErrTooSmall = errors.New("too small to be an executable")
	ErrNotELF   = errors.New("not a Linux (ELF) executable")
	ErrMachO    = errors.New("a macOS binary — the server needs a Linux build")
)

// headerBytes covers the ELF magic and the e_machine field at offset 18.
const headerBytes = 20

// Check reads the leading bytes of a binary and returns its architecture.
// It reads only the header, so it can run against the first bytes of an upload
// without pulling down the whole object.
func Check(r io.Reader) (string, error) {
	head := make([]byte, headerBytes)
	if _, err := io.ReadFull(r, head); err != nil {
		return "", ErrTooSmall
	}

	if !(head[0] == 0x7f && head[1] == 'E' && head[2] == 'L' && head[3] == 'F') {
		// Mach-O magic (0xcffaedfe LE / 0xfeedfacf BE) — say it plainly,
		// because it means someone deployed the binary they just built on
		// their laptop.
		if (head[0] == 0xcf || head[0] == 0xce) && head[1] == 0xfa && head[2] == 0xed && head[3] == 0xfe ||
			head[0] == 0xfe && head[1] == 0xed && head[2] == 0xfa {
			return "", ErrMachO
		}
		return "", ErrNotELF
	}

	switch binary.LittleEndian.Uint16(head[18:20]) {
	case 0x3e:
		return ArchAMD64, nil
	case 0xb7:
		return ArchARM64, nil
	default:
		return fmt.Sprintf("machine 0x%x", binary.LittleEndian.Uint16(head[18:20])), nil
	}
}

// CheckFile is Check against a file on disk, with the path in the error.
func CheckFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	arch, err := Check(f)
	if err != nil {
		return "", fmt.Errorf("%s is %w", path, err)
	}
	return arch, nil
}
