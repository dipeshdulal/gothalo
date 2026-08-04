// Command gothalo is the Herdr bridge + CLI: it runs the bridge daemon (serve),
// pairs mobile devices via QR (pair), and manages paired devices (devices).
package main

import "github.com/dipeshdulal/gothalo/internal/cli"

// Build metadata, injected at release time via -ldflags by GoReleaser.
// Defaults keep `go build`/`go install` working with sensible placeholders.
var (
	version = "dev"
	commit  = "none"
	date    = "unknown"
)

func main() {
	cli.Execute(cli.BuildInfo{Version: version, Commit: commit, Date: date})
}
