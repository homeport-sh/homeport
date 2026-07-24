package main

import (
	"net"
	"testing"
)

func TestParseCIDRs(t *testing.T) {
	data := []byte("104.16.0.0/13\n172.64.0.0/13\n\n# junk line\n2606:4700::/32\n")
	nets := parseCIDRs(data)
	if len(nets) != 3 {
		t.Fatalf("want 3 CIDRs, got %d", len(nets))
	}
}

func TestIPsAllWithin(t *testing.T) {
	nets := parseCIDRs([]byte("104.16.0.0/13\n172.64.0.0/13\n2606:4700::/32\n"))

	cases := []struct {
		name string
		ips  []net.IP
		want bool
	}{
		// proxied domain: every A record is Cloudflare anycast
		{"proxied v4", []net.IP{net.ParseIP("104.21.36.20"), net.ParseIP("172.67.183.213")}, true},
		{"proxied v6", []net.IP{net.ParseIP("2606:4700::6810:1234")}, true},
		// direct-to-origin: a Hetzner IP is not in Cloudflare ranges
		{"origin ip", []net.IP{net.ParseIP("116.203.183.59")}, false},
		// mixed (grey-cloud + orange, or split DNS) must NOT count as proxied —
		// HTTP-01 might still work, and claiming CF would be wrong half the time
		{"mixed", []net.IP{net.ParseIP("104.21.36.20"), net.ParseIP("116.203.183.59")}, false},
		{"no ips", nil, false},
	}
	for _, c := range cases {
		if got := ipsAllWithin(c.ips, nets); got != c.want {
			t.Errorf("%s: ipsAllWithin = %v, want %v", c.name, got, c.want)
		}
	}
}
