// Command gothalo is the Herdr bridge + CLI: it runs the bridge daemon (serve),
// pairs mobile devices via QR (pair), and manages paired devices (devices).
package main

import "github.com/dipeshdulal/gothalo/internal/cli"

func main() {
	cli.Execute()
}
