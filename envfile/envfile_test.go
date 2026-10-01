package envfile_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/homeport-sh/homeport/envfile"
)

func TestNames(t *testing.T) {
	for name, want := range map[string]bool{
		"DATABASE_URL": true, "_PRIVATE": true, "lower_ok": true, "A1": true,
		"": false, "1ABC": false, "WITH-DASH": false, "WITH SPACE": false, "A=B": false, "Ä": false,
	} {
		if got := envfile.ValidName(name); got != want {
			t.Errorf("%q: %v, want %v", name, got, want)
		}
	}
}

func TestEncodingEscapesExactlyWhatHomeportdUnescapes(t *testing.T) {
	for in, want := range map[string]string{
		"plain":                `"plain"`,
		"":                     `""`,
		`back\slash`:           `"back\\slash"`,
		`quo"te`:               `"quo\"te"`,
		"tick`cmd`":            "\"tick\\`cmd\\`\"",
		"$HOME and ${X}":       `"\$HOME and \${X}"`,
		"  spaced  ":           `"  spaced  "`,
		"it's # not a comment": `"it's # not a comment"`,
	} {
		if got := envfile.Encode(in); got != want {
			t.Errorf("Encode(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestALineIsOneLine(t *testing.T) {
	if l, err := envfile.Line("KEY", `v"1`); err != nil || l != `KEY="v\"1"` {
		t.Fatalf("%q, %v", l, err)
	}
	for name, val := range map[string]string{
		"bad name": "x", "newline": "a\nb", "carriage return": "a\rb", "nul": "a\x00b",
	} {
		n := "KEY"
		if name == "bad name" {
			n = "1BAD"
		}
		if _, err := envfile.Line(n, val); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

// What Go encodes, homeportd's own decoder must read back exactly — run it.
func TestHomeportdDecodesWhatGoEncodes(t *testing.T) {
	bash := os.Getenv("BASH")
	if bash == "" {
		bash = "bash"
	}
	script, err := os.ReadFile(filepath.Join("..", "bootstrap", "bootstrap.sh"))
	if err != nil {
		t.Fatal(err)
	}
	s := string(script)
	start := strings.Index(s, "<<'HOMEPORTD_SCRIPT'\n")
	end := strings.Index(s, "\nHOMEPORTD_SCRIPT\n")
	if start < 0 || end < 0 {
		t.Fatal("homeportd not found in bootstrap.sh")
	}
	hd := filepath.Join(t.TempDir(), "homeportd")
	if err := os.WriteFile(hd, []byte(s[start+len("<<'HOMEPORTD_SCRIPT'\n"):end+1]), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, v := range []string{
		"plain", "", `back\slash`, `trailing\`, `\\double`, `quo"te`, `"wrapped"`, "tick`id`",
		"$HOME ${X} $(id)", "  spaced  ", "tab\there", "unicode ✓ é", `a\nb (literal backslash-n)`, `\$`,
	} {
		out, err := exec.Command(bash, "-c", `source "$1"; env_decode_value "$2"`, "_", hd, envfile.Encode(v)).CombinedOutput()
		if err != nil {
			t.Fatalf("bash (%s, set BASH to bash >= 4): %v\n%s", bash, err, out)
		}
		if string(out) != v {
			t.Errorf("%q: encoded %s, homeportd decoded %q", v, envfile.Encode(v), out)
		}
	}
}
