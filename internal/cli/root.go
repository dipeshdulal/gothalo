// Package cli wires the gothalo cobra command tree (serve / pair / devices).
package cli

import (
	"fmt"
	"os"
	"runtime"

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
	root.AddCommand(newServeCmd(), newPairCmd(), newDevicesCmd(), newVersionCmd(b))
	return root
}

func newVersionCmd(b BuildInfo) *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print version, commit, and build date",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Printf("gothalo %s\n", b.Version)
			fmt.Printf("  commit: %s\n", b.Commit)
			fmt.Printf("  built:  %s\n", b.Date)
			fmt.Printf("  go:     %s %s/%s\n", runtime.Version(), runtime.GOOS, runtime.GOARCH)
		},
	}
}

// Execute runs the root command and exits non-zero on error.
func Execute(b BuildInfo) {
	if err := newRootCmd(b).Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
