package main

import (
	"fmt"
	"testing"
)

// Must accept/reject exactly what homeportd's valid_origin_secret does — the
// CLI check exists to fail before the ssh round trip, not to be looser.
func TestOriginSecretRe(t *testing.T) {
	for s, want := range map[string]bool{
		"Zx9_k-3QpL7mN2vR8tY4wE6uI1oA5sD0fG_hJ-kLzXc": true,
		"short": false,
		`Zx9_k-3QpL7mN2vR8tY4wE6uI1oA5sD0fG_hJ-kLz"`:  false,
		"Zx9_k-3QpL7mN2vR8tY4wE6uI1oA5sD0fG_hJ-kLz}":  false,
		"Zx9_k-3QpL7mN2vR8tY4wE6uI1oA5sD0fG_hJ-kL z":  false,
		"Zx9_k-3QpL7mN2vR8tY4wE6uI1oA5sD0fG_hJ-kLz$":  false,
		"Zx9_k-3QpL7mN2vR8tY4wE6uI1oA5sD0fG_hJ-kLz\n": false,
	} {
		if got := originSecretRe.MatchString(s); got != want {
			t.Errorf("%q: got %v want %v", s, got, want)
		}
	}
}

// A truncated or garbage Cloudflare list must never become the firewall policy:
// narrowing the allow-list blackholes every proxied site on the box.
func TestCheckCloudflareCIDRs(t *testing.T) {
	var full []string
	for i := 0; i < 15; i++ {
		full = append(full, fmt.Sprintf("104.%d.0.0/13", i))
	}
	full = append(full, "2400:cb00::/32", "2606:4700::/32")
	if err := checkCloudflareCIDRs(full); err != nil {
		t.Fatalf("full list rejected: %v", err)
	}
	for name, list := range map[string][]string{
		"empty":        nil,
		"truncated v4": full[:3],
		"v6 only":      {"2400:cb00::/32", "2606:4700::/32"},
		"catch-all":    append(append([]string{}, full...), "0.0.0.0/0"),
	} {
		if err := checkCloudflareCIDRs(list); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
