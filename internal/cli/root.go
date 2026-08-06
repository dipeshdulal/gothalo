// Package cli wires the gothalo cobra command tree (serve / pair / devices /
// push).
package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

// BuildInfo carries release metadata injected by main (set at build time via
// -ldflags by GoReleaser). Defaults keep plain `go build` working.
type BuildInfo struct {
	Version string
	Commit  string
	Date    string
}

func newRootCmd(b BuildInfo) *cobra.Command {
	root := &cobra.Command{
		Use:           "gothalo",
		Short:         "Self-hosted mobile remote for Herdr — bridge + CLI",
		Version:       b.Version,
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.SetVersionTemplate("gothalo {{.Version}}\n")
	root.AddCommand(
		newServeCmd(), newPairCmd(), newDevicesCmd(), newPushCmd(), newVersionCmd(b),
	)
	return root
}

// Execute runs the root command and exits non-zero on error.
func Execute(b BuildInfo) {
	if err := newRootCmd(b).Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
