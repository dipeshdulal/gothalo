// Package cli wires the gothalo cobra command tree (serve / pair / devices /
// push).
package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

func newRootCmd() *cobra.Command {
	root := &cobra.Command{
		Use:           "gothalo",
		Short:         "Self-hosted mobile remote for Herdr — bridge + CLI",
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.AddCommand(newServeCmd(), newPairCmd(), newDevicesCmd(), newPushCmd(), newVersionCmd())
	return root
}

// Execute runs the root command and exits non-zero on error.
func Execute() {
	if err := newRootCmd().Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
