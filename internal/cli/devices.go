package cli

import (
	"fmt"
	"os"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/store"
)

func newDevicesCmd() *cobra.Command {
	var configPath string
	cmd := &cobra.Command{
		Use:   "devices",
		Short: "List and revoke paired mobile devices",
	}
	cmd.PersistentFlags().StringVarP(&configPath, "config", "c", "", "path to config file (default ~/.gothalo/config.json)")
	cmd.AddCommand(
		&cobra.Command{
			Use:   "list",
			Short: "List paired devices",
			RunE: func(cmd *cobra.Command, args []string) error {
				return runDevicesList(configPath)
			},
		},
		&cobra.Command{
			Use:   "revoke <id>",
			Short: "Revoke a paired device by id",
			Args:  cobra.ExactArgs(1),
			RunE: func(cmd *cobra.Command, args []string) error {
				return runDevicesRevoke(configPath, args[0])
			},
		},
	)
	return cmd
}

func devicesClient(configPath string) (*daemonClient, error) {
	cfg, err := config.Load(configPath)
	if err != nil {
		return nil, err
	}
	if cfg.AdminToken == "" {
		return nil, fmt.Errorf("no admin token yet — start `gothalo serve` once to generate one")
	}
	return newDaemonClient(cfg.Transport.Addr, cfg.AdminToken), nil
}

func runDevicesList(configPath string) error {
	client, err := devicesClient(configPath)
	if err != nil {
		return err
	}
	var res struct {
		Devices []store.Device `json:"devices"`
	}
	if err := client.do("GET", "/admin/devices", nil, &res); err != nil {
		return err
	}
	if len(res.Devices) == 0 {
		fmt.Println("no paired devices")
		return nil
	}
	tw := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tNAME\tPAIRED\tLAST SEEN")
	for _, d := range res.Devices {
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", d.ID, d.Name,
			d.PairedAt.Format("2006-01-02 15:04"), humanSince(d.LastSeen))
	}
	return tw.Flush()
}

func runDevicesRevoke(configPath, id string) error {
	client, err := devicesClient(configPath)
	if err != nil {
		return err
	}
	var res struct {
		Revoked bool   `json:"revoked"`
		Name    string `json:"name"`
	}
	if err := client.do("POST", "/admin/devices/revoke", map[string]string{"id": id}, &res); err != nil {
		return err
	}
	fmt.Printf("revoked %q — its bearer no longer authenticates and it will receive no further pushes\n", res.Name)
	return nil
}

func humanSince(t time.Time) string {
	if t.IsZero() {
		return "never"
	}
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}
