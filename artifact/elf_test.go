package artifact_test

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/homeport-sh/homeport/artifact"
)

// elf builds a header with the given e_machine, which is all Check reads.
func elf(machine uint16) []byte {
	b := make([]byte, 20)
	copy(b, []byte{0x7f, 'E', 'L', 'F'})
	b[18] = byte(machine)
	b[19] = byte(machine >> 8)
	return b
}

func TestCheckReadsTheArchitecture(t *testing.T) {
	for _, tc := range []struct {
		machine uint16
		want    string
	}{
		{0x3e, artifact.ArchAMD64},
		{0xb7, artifact.ArchARM64},
	} {
		got, err := artifact.Check(bytes.NewReader(elf(tc.machine)))
		if err != nil {
			t.Fatalf("machine %#x: %v", tc.machine, err)
		}
		if got != tc.want {
			t.Errorf("machine %#x: got %q, want %q", tc.machine, got, tc.want)
		}
	}
}

// An ELF for hardware we do not run is reported rather than refused: it is a
// real Linux binary, and the caller decides whether the target box can run it.
func TestCheckReportsUnknownMachines(t *testing.T) {
	got, err := artifact.Check(bytes.NewReader(elf(0x0028))) // 32-bit ARM
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(got, "0x28") {
		t.Errorf("got %q, want the machine id", got)
	}
}

func TestCheckRefuses(t *testing.T) {
	machO := []byte{0xcf, 0xfa, 0xed, 0xfe}
	machOBig := []byte{0xfe, 0xed, 0xfa, 0xcf}

	for _, tc := range []struct {
		name string
		in   []byte
		want error
	}{
		{"empty", nil, artifact.ErrTooSmall},
		{"a header cut short", elf(0x3e)[:12], artifact.ErrTooSmall},
		{"a macOS binary", append(machO, make([]byte, 16)...), artifact.ErrMachO},
		{"a big-endian macOS binary", append(machOBig, make([]byte, 16)...), artifact.ErrMachO},
		{"a shell script", []byte("#!/bin/sh\necho hello\n#pad"), artifact.ErrNotELF},
		{"a zip", append([]byte{'P', 'K', 3, 4}, make([]byte, 16)...), artifact.ErrNotELF},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := artifact.Check(bytes.NewReader(tc.in))
			if !errors.Is(err, tc.want) {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
		})
	}
}

func TestCheckFileNamesThePath(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "server")
	if err := os.WriteFile(path, append([]byte{0xcf, 0xfa, 0xed, 0xfe}, make([]byte, 16)...), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := artifact.CheckFile(path)
	if !errors.Is(err, artifact.ErrMachO) {
		t.Fatalf("got %v, want %v", err, artifact.ErrMachO)
	}
	if !strings.Contains(err.Error(), path) {
		t.Errorf("error does not name the file: %v", err)
	}
}

func TestCheckFileMissing(t *testing.T) {
	if _, err := artifact.CheckFile(filepath.Join(t.TempDir(), "nope")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("got %v, want a not-exist error", err)
	}
}
