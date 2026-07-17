package main

import (
	"os"
	"path/filepath"
	"strings"
)

// The CLI remembers the last server it bootstrapped or initialized against,
// so `homeport init` can offer it as the default — you name an IP once, at
// bootstrap, and press Enter everywhere after.

func stateFile() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "homeport", "last-server")
}

func lastServer() string {
	f := stateFile()
	if f == "" {
		return ""
	}
	data, err := os.ReadFile(f)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func saveLastServer(server string) {
	f := stateFile()
	if f == "" {
		return
	}
	// best-effort — a failed save must never fail the command
	if os.MkdirAll(filepath.Dir(f), 0o755) == nil {
		_ = os.WriteFile(f, []byte(server+"\n"), 0o644)
	}
}

// normalizeServer fills in the only user homeport ever deploys as — the
// `deploy` user bootstrap creates. A bare IP or hostname is enough.
func normalizeServer(s string) string {
	if s != "" && !strings.Contains(s, "@") {
		return "deploy@" + s
	}
	return s
}
