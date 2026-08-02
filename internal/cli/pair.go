package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/pairing"
)

func newPairCmd() *cobra.Command {
	var (
		configPath string
		name       string
	)
	cmd := &cobra.Command{
		Use:   "pair",
		Short: "Print a QR code to pair a mobile device",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runPair(configPath, name)
		},
	}
	cmd.Flags().StringVarP(&configPath, "config", "c", "", "path to config file (default ~/.gothalo/config.json)")
	cmd.Flags().StringVarP(&name, "name", "n", "", "label for the device being paired")
	return cmd
}

func runPair(configPath, name string) error {
	cfg, err := config.Load(configPath)
	if err != nil {
		return err
	}
	if cfg.AdminToken == "" {
		return fmt.Errorf("no admin token yet — start `gothalo serve` once to generate one")
	}

	client := newDaemonClient(cfg.Transport.Addr, cfg.AdminToken)
	var res struct {
		Code string `json:"code"`
		URL  string `json:"url"`
	}
	if err := client.do("POST", "/admin/pairing", map[string]string{"name": name}, &res); err != nil {
		return err
	}
	if res.URL == "" {
		fmt.Fprintln(os.Stderr, "warning: no public_url configured — the QR has no reachable URL for the phone")
	}

	fmt.Println(titleStyle.Render("Scan this with the gothalo app to pair") +
		hintStyle.Render("  (valid ~5 min)"))
	fmt.Println()
	if err := pairing.RenderQR(pairing.ConnectPayload{V: 1, URL: res.URL, Code: res.Code}, os.Stdout); err != nil {
		return err
	}
	return nil
}
