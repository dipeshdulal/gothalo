package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/pairing"
)

func newPairCmd() *cobra.Command {
	var configPath string
	cmd := &cobra.Command{
		Use:   "pair",
		Short: "Print a QR code to pair a mobile device",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runPair(configPath)
		},
	}
	cmd.Flags().StringVarP(&configPath, "config", "c", "", "path to config file (default ~/.gothalo/config.json)")
	return cmd
}

func runPair(configPath string) error {
	cfg, err := config.Load(configPath)
	if err != nil {
		return err
	}
	if cfg.AdminToken == "" {
		return fmt.Errorf("no admin token yet — start `gothalo serve` once to generate one")
	}

	client := newDaemonClient(cfg.Transport.Addr, cfg.AdminToken)
	var res struct {
		Code    string `json:"code"`
		PairURL string `json:"pair_url"`
	}
	if err := client.do("POST", "/admin/pairing", nil, &res); err != nil {
		return err
	}
	if res.PairURL == "" || cfg.Transport.PublicURL == "" {
		fmt.Fprintln(os.Stderr, "warning: no public_url configured — the QR has no reachable URL for the phone")
	}

	fmt.Println(titleStyle.Render("Scan this with the gothalo app to pair") +
		hintStyle.Render("  (valid ~5 min)"))
	fmt.Println()
	return pairing.RenderQR(res.PairURL, os.Stdout)
}
