package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"os"
	"regexp"
	"strings"
	"time"

	homeport "github.com/homeport-sh/homeport"
	"golang.org/x/term"
)

// cmdServer manages the box itself (as opposed to an app on it).
//
//	homeport server update [deploy@host]
//	homeport server plugins [add <module>... | rm <module>] [deploy@host]
//
// `update` pushes the homeportd bundled inside THIS CLI binary to the server
// via `homeportd self-update` — the post-hardening update path (root SSH is
// disabled, so re-running bootstrap isn't possible). CLI and server helper
// stay in lockstep because the script travels inside the binary.
// `plugins` swaps Caddy for an official caddyserver.com build with the named
// plugin modules baked in (nothing compiles on the box).
func cmdServer(args []string) error {
	const use = "usage: homeport server <update | plugins [add|rm …] | firewall [allow <file>|clear]> [deploy@host]"
	if len(args) < 1 {
		return fmt.Errorf("%s", use)
	}
	switch args[0] {
	case "update":
		target, err := serverTarget(args[1:])
		if err != nil {
			return err
		}
		script, err := embeddedHomeportd()
		if err != nil {
			return err
		}
		step("updating homeportd on %s", target)
		if err := sshRunIn(target, "sudo /usr/local/bin/homeportd self-update", script); err != nil {
			return fmt.Errorf("self-update failed — a homeportd from before v0.1.0 lacks this command; "+
				"update those boxes via Hetzner rescue mode, or recreate them (%w)", err)
		}
		return sshRun(target, "sudo /usr/local/bin/homeportd version")
	case "plugins":
		return cmdServerPlugins(args[1:])
	case "firewall":
		return cmdServerFirewall(args[1:])
	case "caddy-env":
		return cmdServerCaddyEnv(args[1:])
	case "dns", "ech", "globals":
		return cmdServerGlobals(args[0], args[1:])
	default:
		return fmt.Errorf("%s", use)
	}
}

// cmdServerGlobals drives the homeport-managed Caddy global options:
//
//	homeport server dns <provider>|off        global DNS module (DNS-01 default + ECH publication)
//	homeport server ech <public-name>|off     Encrypted Client Hello (needs `server dns` first)
//	homeport server globals                   show the current managed global options
func cmdServerGlobals(sub string, args []string) error {
	host := []string{}
	if n := len(args); n > 0 && strings.Contains(args[n-1], "@") {
		host, args = args[n-1:], args[:n-1]
	}
	target, err := serverTarget(host)
	if err != nil {
		return err
	}
	hd := "sudo /usr/local/bin/homeportd "
	switch sub {
	case "globals":
		return sshRun(target, hd+"global-list")
	case "dns":
		if len(args) < 1 || len(args) > 2 {
			return fmt.Errorf("usage: homeport server dns <provider [ENV_NAME] | off> [deploy@host]")
		}
		if args[0] == "off" {
			return sshRun(target, hd+"global-dns -")
		}
		if !bareProviderRe.MatchString(args[0]) {
			return fmt.Errorf("invalid dns provider %q (e.g. cloudflare, digitalocean)", args[0])
		}
		cmd := hd + "global-dns " + args[0]
		if len(args) == 2 {
			if args[1] != "none" && !envNameRe.MatchString(args[1]) {
				return fmt.Errorf("invalid env var name %q (A-Z, digits, _; or 'none')", args[1])
			}
			cmd += " " + args[1]
		}
		return sshRun(target, cmd)
	case "ech":
		if len(args) != 1 {
			return fmt.Errorf("usage: homeport server ech <public-name|off> [deploy@host]")
		}
		if args[0] == "off" {
			return sshRun(target, hd+"global-ech -")
		}
		if args[0] == "rotate" {
			return sshRun(target, hd+"global-ech-rotate")
		}
		if !domainRe.MatchString(args[0]) {
			return fmt.Errorf("ech public name %q doesn't look like a domain", args[0])
		}
		return sshRun(target, hd+"global-ech "+args[0])
	}
	return nil
}

// cmdServerCaddyEnv manages env vars for Caddy itself — DNS-provider tokens
// for `tls: dns:<provider>` (DNS-01 certs):
//
//	homeport server caddy-env                 list names (values never printed)
//	homeport server caddy-env NAME            set NAME from stdin (or a hidden prompt)
//	homeport server caddy-env rm NAME         remove
//
// The value travels over ssh stdin — never argv, never shell history.
func cmdServerCaddyEnv(args []string) error {
	host := []string{}
	if n := len(args); n > 0 && strings.Contains(args[n-1], "@") {
		host, args = args[n-1:], args[:n-1]
	}
	target, err := serverTarget(host)
	if err != nil {
		return err
	}
	switch {
	case len(args) == 0:
		return sshRun(target, "sudo /usr/local/bin/homeportd caddy-env-list")
	case args[0] == "rm" && len(args) == 2:
		if !envNameRe.MatchString(args[1]) {
			return fmt.Errorf("invalid env var name %q (A-Z, digits, _)", args[1])
		}
		return sshRun(target, "sudo /usr/local/bin/homeportd caddy-env-rm "+args[1])
	case len(args) == 1 && args[0] != "rm":
		name := args[0]
		if !envNameRe.MatchString(name) {
			return fmt.Errorf("invalid env var name %q (A-Z, digits, _)", name)
		}
		val, err := readSecretLine(fmt.Sprintf("value for %s (input hidden, Enter submits): ", name))
		if err != nil {
			return err
		}
		if val == "" {
			return fmt.Errorf("empty value")
		}
		return sshRunIn(target, "sudo /usr/local/bin/homeportd caddy-env-set "+name, val+"\n")
	default:
		return fmt.Errorf("usage: homeport server caddy-env [NAME | rm NAME] [deploy@host]")
	}
}

// cmdServerFirewall restricts (or reopens) web ingress on the box:
//
//	homeport server firewall                          show the current policy
//	homeport server firewall allow <file|-|cloudflare>  restrict 80/443 to these CIDRs
//	homeport server firewall clear                    reopen 80/443 to the world
//
// The file is declarative — one CIDR per line (# comments ok), and the list
// replaces the previous policy wholesale. SSH is never touched. The literal
// keyword "cloudflare" fetches Cloudflare's current edge ranges instead of a
// file — the one-command way to lock the origin behind the Cloudflare proxy.
func cmdServerFirewall(args []string) error {
	host := []string{}
	if n := len(args); n > 0 && strings.Contains(args[n-1], "@") {
		host, args = args[n-1:], args[:n-1]
	}
	target, err := serverTarget(host)
	if err != nil {
		return err
	}
	if len(args) == 0 {
		return sshRun(target, "sudo /usr/local/bin/homeportd firewall-list")
	}
	switch args[0] {
	case "allow":
		if len(args) != 2 {
			return fmt.Errorf("usage: homeport server firewall allow <file|-|cloudflare> [deploy@host]")
		}
		var data []byte
		switch args[1] {
		case "-":
			data, err = io.ReadAll(io.LimitReader(os.Stdin, 65536))
		case "cloudflare":
			data, err = fetchCloudflareCIDRs()
		default:
			data, err = os.ReadFile(args[1])
		}
		if err != nil {
			return err
		}
		cidrs, err := parseCIDRList(data)
		if err != nil {
			return err
		}
		return sshRunIn(target, "sudo /usr/local/bin/homeportd firewall-set", strings.Join(cidrs, "\n")+"\n")
	case "clear":
		return sshRun(target, "sudo /usr/local/bin/homeportd firewall-clear")
	default:
		return fmt.Errorf("usage: homeport server firewall [allow <file|-> | clear] [deploy@host]")
	}
}

// readSecretLine reads ONE line of secret input — like a password prompt:
// Enter submits, and on a terminal the input is not echoed. Piped stdin
// (e.g. `pbpaste | homeport server caddy-env X`) takes the first line.
func readSecretLine(prompt string) (string, error) {
	if term.IsTerminal(int(os.Stdin.Fd())) {
		fmt.Fprint(os.Stderr, prompt)
		b, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(b)), nil
	}
	line, err := bufio.NewReader(io.LimitReader(os.Stdin, 4096)).ReadString('\n')
	if err != nil && err != io.EOF {
		return "", err
	}
	return strings.TrimSpace(line), nil
}

// parseCIDRList extracts and validates CIDR ranges from a policy file: one per
// line, blank lines and # comments ignored. Validated client-side (exact
// stdlib parse) so a typo fails before it reaches the box's firewall.
func parseCIDRList(data []byte) ([]string, error) {
	var cidrs []string
	for i, line := range strings.Split(string(data), "\n") {
		if idx := strings.Index(line, "#"); idx >= 0 {
			line = line[:idx]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if _, err := netip.ParsePrefix(line); err != nil {
			return nil, fmt.Errorf("line %d: %q is not a valid CIDR (e.g. 103.21.244.0/22)", i+1, line)
		}
		cidrs = append(cidrs, line)
	}
	if len(cidrs) == 0 {
		return nil, fmt.Errorf("no CIDR ranges found (one per line; # comments allowed)")
	}
	if len(cidrs) > 200 {
		return nil, fmt.Errorf("too many ranges (%d, max 200)", len(cidrs))
	}
	return cidrs, nil
}

// Cloudflare's official published edge ranges. Fetched (not hardcoded) so the
// allow-list tracks Cloudflare as it adds ranges. https://www.cloudflare.com/ips/
const (
	cloudflareIPsV4URL = "https://www.cloudflare.com/ips-v4"
	cloudflareIPsV6URL = "https://www.cloudflare.com/ips-v6"
)

// fetchCloudflareCIDRs returns Cloudflare's current edge IP ranges (v4 + v6) as
// a newline-separated CIDR list, ready for parseCIDRList. Restricting 80/443 to
// these is the real origin protection behind the Cloudflare proxy: the origin
// IP is already public in DNS history, so hiding it isn't the point — dropping
// packets that didn't come from Cloudflare is.
func fetchCloudflareCIDRs() ([]byte, error) {
	var buf bytes.Buffer
	for _, url := range []string{cloudflareIPsV4URL, cloudflareIPsV6URL} {
		body, err := httpGetLimited(url, 65536)
		if err != nil {
			return nil, fmt.Errorf("fetching Cloudflare IP ranges from %s: %w", url, err)
		}
		buf.Write(bytes.TrimSpace(body))
		buf.WriteByte('\n')
	}
	return buf.Bytes(), nil
}

// httpGetLimited GETs a URL with a short timeout and caps the body it reads.
func httpGetLimited(url string, limit int64) ([]byte, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, limit))
}

// serverTarget resolves the box to operate on: an explicit deploy@host arg
// wins, else the server from the local homeport.yaml.
func serverTarget(args []string) (string, error) {
	if len(args) > 0 {
		target := normalizeServer(args[0])
		return target, validServer(target)
	}
	cfg, err := loadConfig()
	if err != nil {
		return "", fmt.Errorf("no target given and %w", err)
	}
	return cfg.Server, nil
}

// caddyModuleRe mirrors homeportd's valid_caddy_module: a Go module repo path.
// Checked client-side too so a typo fails before any SSH round-trip.
// bareProviderRe: a caddy-dns provider short name (the part after "dns:").
var bareProviderRe = regexp.MustCompile(`^[a-z0-9-]{1,40}$`)

var caddyModuleRe = regexp.MustCompile(`^[a-z0-9][a-zA-Z0-9._-]*(/[a-zA-Z0-9._-]+)+$`)

func validCaddyModule(m string) error {
	if len(m) > 200 || strings.Contains(m, "..") || !caddyModuleRe.MatchString(m) {
		return fmt.Errorf("invalid plugin module %q — expected a repo path like github.com/caddy-dns/cloudflare", m)
	}
	return nil
}

func cmdServerPlugins(args []string) error {
	// an optional trailing deploy@host applies to any form
	host := []string{}
	if n := len(args); n > 0 && strings.Contains(args[n-1], "@") {
		host, args = args[n-1:], args[:n-1]
	}
	target, err := serverTarget(host)
	if err != nil {
		return err
	}
	if len(args) == 0 { // list
		return sshRun(target, "sudo /usr/local/bin/homeportd caddy-plugin-list")
	}
	verb, modules := args[0], args[1:]
	if (verb != "add" && verb != "rm") || len(modules) == 0 || (verb == "rm" && len(modules) != 1) {
		return fmt.Errorf("usage: homeport server plugins [add <module>... | rm <module>] [deploy@host]")
	}
	for _, m := range modules {
		if err := validCaddyModule(m); err != nil {
			return err
		}
	}
	return sshRun(target, "sudo /usr/local/bin/homeportd caddy-plugin-"+verb+" "+strings.Join(modules, " "))
}

// embeddedHomeportd extracts the homeportd script from the bundled
// bootstrap between its heredoc markers.
func embeddedHomeportd() (string, error) {
	const startMarker = "<<'HOMEPORTD_SCRIPT'\n"
	const endMarker = "\nHOMEPORTD_SCRIPT\n"
	s := homeport.BootstrapScript
	start := strings.Index(s, startMarker)
	if start < 0 {
		return "", fmt.Errorf("bundled bootstrap has no embedded homeportd (build corrupt?)")
	}
	s = s[start+len(startMarker):]
	end := strings.Index(s, endMarker)
	if end < 0 {
		return "", fmt.Errorf("bundled homeportd is unterminated (build corrupt?)")
	}
	return s[:end] + "\n", nil
}
