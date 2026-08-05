package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/dipeshdulal/gothalo/internal/server"
)

// newVersionCmd prints the bridge's capability level — the same number `GET
// /info` reports and the app compares against.
//
// It exists so "what is this host running?" can be answered on the host itself,
// without an admin token and a curl. That question comes up precisely when
// something is wrong: a phone that cannot route a machine's notifications is
// almost always a bridge that predates the capability the app is looking for.
func newVersionCmd() *cobra.Command {
	var quiet bool
	cmd := &cobra.Command{
		Use:   "version",
		Short: "Print the bridge version",
		RunE: func(cmd *cobra.Command, args []string) error {
			if quiet {
				// Bare number, for scripting a fleet check.
				fmt.Fprintln(cmd.OutOrStdout(), server.BridgeVersion)
				return nil
			}
			fmt.Fprintf(cmd.OutOrStdout(), "gothalo bridge version %d\n", server.BridgeVersion)
			return nil
		},
	}
	cmd.Flags().BoolVarP(&quiet, "quiet", "q", false, "print just the number")
	return cmd
}
