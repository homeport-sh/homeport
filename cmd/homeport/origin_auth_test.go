package main

import "testing"

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
