package main

import (
	"fmt"
	"os"
	"strings"
)

// cmdTLS manages a bring-your-own TLS cert for the app in the current
// homeport.yaml — for running behind a TLS-terminating proxy (e.g. a
// Cloudflare Origin Certificate) where Caddy can't provision its own.
//
//	homeport tls set <cert.pem> <key.pem>   upload a cert + key (over ssh stdin)
//	homeport tls clear                      revert to automatic HTTPS
//
// The cert+key travel over ssh stdin, never argv — the private key is a secret
// and is handled like one. Pair with `tls: manual` in homeport.yaml so redeploys
// keep serving it.
func cmdTLS(args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: homeport tls <set <cert.pem> <key.pem> | clear>")
	}
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	switch args[0] {
	case "set":
		if len(args) != 3 {
			return fmt.Errorf("usage: homeport tls set <cert.pem> <key.pem>")
		}
		cert, err := os.ReadFile(args[1])
		if err != nil {
			return fmt.Errorf("reading cert: %w", err)
		}
		key, err := os.ReadFile(args[2])
		if err != nil {
			return fmt.Errorf("reading key: %w", err)
		}
		if !strings.Contains(string(cert), "-----BEGIN CERTIFICATE-----") {
			return fmt.Errorf("%s does not look like a PEM certificate", args[1])
		}
		if !strings.Contains(string(key), "PRIVATE KEY-----") {
			return fmt.Errorf("%s does not look like a PEM private key", args[2])
		}
		// cert + key travel over ssh stdin (never argv), split by a marker line
		// homeportd knows. TrimRight so the marker sits on its own line.
		blob := strings.TrimRight(string(cert), "\n") +
			"\n##HOMEPORT_TLS_KEY##\n" +
			strings.TrimRight(string(key), "\n") + "\n"
		if err := sshRunIn(cfg.Server, cfg.homeportd("tls-set", cfg.App), blob); err != nil {
			return err
		}
		// without tls: manual in the yaml, the next deploy re-registers the app
		// as auto and silently drops this cert — that's a broken site behind a
		// TLS-terminating proxy, so make the mismatch loud.
		if cfg.TLS != "manual" {
			fmt.Fprintln(os.Stderr, "warning: homeport.yaml does not set `tls: manual` — the next deploy will revert this app to automatic HTTPS and stop serving the uploaded cert")
		}
		return nil
	case "clear":
		return sshRun(cfg.Server, cfg.homeportd("tls-clear", cfg.App))
	default:
		return fmt.Errorf("usage: homeport tls <set <cert.pem> <key.pem> | clear>")
	}
}
