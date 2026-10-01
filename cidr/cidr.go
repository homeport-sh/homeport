// Package cidr validates CIDR allow-lists and fetches Cloudflare's edge
// ranges, failing closed on anything that can't be the whole list. Shared by
// the homeport CLI (homeport server firewall) and homeport cloud (a new
// host's web firewall), so both apply exactly the same checks.
package cidr

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"strings"
	"time"
)

// Parse extracts and validates CIDR ranges from a policy file: one per
// line, blank lines and # comments ignored. Validated client-side (exact
// stdlib parse) so a typo fails before it reaches the box's firewall.
func Parse(data []byte) ([]string, error) {
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

// FetchCloudflare returns Cloudflare's current edge IP ranges (v4 + v6) as
// a newline-separated CIDR list, ready for Parse. Restricting 80/443 to
// these is the real origin protection behind the Cloudflare proxy: the origin
// IP is already public in DNS history, so hiding it isn't the point — dropping
// packets that didn't come from Cloudflare is.
func FetchCloudflare() ([]byte, error) {
	var buf bytes.Buffer
	for _, url := range []string{cloudflareIPsV4URL, cloudflareIPsV6URL} {
		body, err := httpGetLimited(url, 65536)
		if err != nil {
			return nil, fmt.Errorf("fetching Cloudflare IP ranges from %s: %w", url, err)
		}
		buf.Write(bytes.TrimSpace(body))
		buf.WriteByte('\n')
	}
	cidrs, err := Parse(buf.Bytes())
	if err != nil {
		return nil, fmt.Errorf("Cloudflare's IP list didn't parse — refusing to apply it: %w", err)
	}
	if err := CheckCloudflare(cidrs); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// CheckCloudflare fails closed on a list that can't be Cloudflare's whole
// edge: a truncated or garbled fetch applied as the policy would narrow the
// allow-list and blackhole every proxied site, and a catch-all would silently
// reopen the origin. Cloudflare publishes ~15 IPv4 ranges; fewer than 10 is a
// bad fetch, not a change worth trusting.
func CheckCloudflare(cidrs []string) error {
	v4 := 0
	for _, c := range cidrs {
		p, err := netip.ParsePrefix(c)
		if err != nil {
			return fmt.Errorf("Cloudflare IP list has an invalid range %q — refusing to apply it", c)
		}
		if p.Bits() == 0 {
			return fmt.Errorf("Cloudflare IP list contains the catch-all %s — refusing to apply it", c)
		}
		if p.Addr().Is4() {
			v4++
		}
	}
	if v4 < 10 {
		return fmt.Errorf("Cloudflare IP list looks truncated (%d IPv4 ranges, expected ~15) — refusing to apply it; try again", v4)
	}
	return nil
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
