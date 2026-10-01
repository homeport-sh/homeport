// Package envfile is homeportd's env file format, for Go: the names it
// accepts and the canonical KEY="value" encoding it stores, so systemd and
// bash read every value identically (see env_encode_value in homeportd).
// Shared by the homeport CLI and homeport cloud, which both send env to
// homeportd's env-sync.
package envfile

import (
	"fmt"
	"regexp"
	"strings"
)

var name = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// ValidName reports whether homeportd accepts name as an env var name.
func ValidName(n string) bool { return name.MatchString(n) }

// Encode is homeportd's canonical form of a value: double-quoted, with
// exactly \ " ` $ escaped.
func Encode(v string) string {
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`, "`", "\\`", `$`, `\$`).Replace(v) + `"`
}

// Line is one env-sync line. Values travel one per line, so a newline,
// carriage return or NUL can't be sent and is refused rather than mangled.
func Line(n, v string) (string, error) {
	if !ValidName(n) {
		return "", fmt.Errorf("invalid env var name %q (letters, digits and _, not starting with a digit)", n)
	}
	if strings.ContainsAny(v, "\n\r\x00") {
		return "", fmt.Errorf("%s: a value can't contain a newline, carriage return or NUL", n)
	}
	return n + "=" + Encode(v), nil
}
