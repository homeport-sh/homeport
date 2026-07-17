// Package homeport holds assets shared by the homeport commands.
package homeport

import _ "embed"

// BootstrapScript is the single-file server bootstrap (hardening, Caddy,
// homeportd). It is embedded so `homeport bootstrap` works offline and the CLI
// and the server-side helper always ship in lockstep.
//
//go:embed bootstrap/bootstrap.sh
var BootstrapScript string
