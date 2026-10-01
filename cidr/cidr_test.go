package cidr_test

import (
	"fmt"
	"testing"

	"github.com/homeport-sh/homeport/cidr"
)

func TestParse(t *testing.T) {
	got, err := cidr.Parse([]byte("# Cloudflare v4\n103.21.244.0/22\n\n2400:cb00::/32  # v6\n"))
	if err != nil {
		t.Fatalf("valid list rejected: %v", err)
	}
	if len(got) != 2 || got[0] != "103.21.244.0/22" || got[1] != "2400:cb00::/32" {
		t.Errorf("parsed = %v, want the two ranges", got)
	}
	for label, in := range map[string]string{
		"bare IP":    "103.21.244.0\n",
		"bad octet":  "999.1.1.0/24\n",
		"bad mask":   "10.0.0.0/33\n",
		"injection":  "10.0.0.0/8; rm -rf /\n",
		"only-blank": "# nothing\n\n",
	} {
		if _, err := cidr.Parse([]byte(in)); err == nil {
			t.Errorf("%s: expected rejection, got nil", label)
		}
	}
}

// A truncated or garbage Cloudflare list must never become the firewall policy:
// narrowing the allow-list blackholes every proxied site on the box.
func TestCheckCloudflare(t *testing.T) {
	var full []string
	for i := 0; i < 15; i++ {
		full = append(full, fmt.Sprintf("104.%d.0.0/13", i))
	}
	full = append(full, "2400:cb00::/32", "2606:4700::/32")
	if err := cidr.CheckCloudflare(full); err != nil {
		t.Fatalf("full list rejected: %v", err)
	}
	for name, list := range map[string][]string{
		"empty":        nil,
		"truncated v4": full[:3],
		"v6 only":      {"2400:cb00::/32", "2606:4700::/32"},
		"catch-all":    append(append([]string{}, full...), "0.0.0.0/0"),
	} {
		if err := cidr.CheckCloudflare(list); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
