package cli

import (
	"fmt"
	"runtime"

	"github.com/spf13/cobra"

	"github.com/dipeshdulal/gothalo/internal/server"
)

// newVersionCmd prints what this host is running, in both senses that matter.
//
// Two different questions were being answered by two different `version`
// commands before these branches met, and they are not the same question:
//
//   - WHICH BUILD is this? — the release tag, commit and build date. What you
//     need when a binary was installed from a release and you are asking whether
//     it predates a fix.
//   - WHAT CAN IT DO? — the bridge capability level, the same number `GET /info`
//     reports and the app compares against. What you need when a phone cannot
//     route a machine's notifications, which is almost always a bridge older
//     than the capability the app is looking for.
//
// A binary built from source has no release tag, and a released binary is
// useless to diagnose against without its capability level, so neither answer
// substitutes for the other. Both print.
//
// --quiet stays the capability number alone: it exists for scripting a fleet
// check, and that is the number a fleet check compares.
func newVersionCmd(b BuildInfo) *cobra.Command {
	var quiet bool
	cmd := &cobra.Command{
		Use:   "version",
		Short: "Print the build and the bridge capability level",
		RunE: func(cmd *cobra.Command, args []string) error {
			out := cmd.OutOrStdout()
			if quiet {
				fmt.Fprintln(out, server.BridgeVersion)
				return nil
			}
			fmt.Fprintf(out, "gothalo %s\n", b.Version)
			fmt.Fprintf(out, "  bridge:  %d\n", server.BridgeVersion)
			fmt.Fprintf(out, "  commit:  %s\n", b.Commit)
			fmt.Fprintf(out, "  built:   %s\n", b.Date)
			fmt.Fprintf(out, "  go:      %s %s/%s\n", runtime.Version(), runtime.GOOS, runtime.GOARCH)
			return nil
		},
	}
	cmd.Flags().BoolVarP(&quiet, "quiet", "q", false, "print just the bridge capability number")
	return cmd
}
