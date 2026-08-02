package cli

import (
	"fmt"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/lipgloss/table"
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
		fmt.Println(hintStyle.Render("no paired devices — run `gothalo pair` to add one"))
		return nil
	}
	t := table.New().
		Border(lipgloss.RoundedBorder()).
		BorderStyle(borderStyle).
		Headers("ID", "NAME", "PAIRED", "LAST SEEN").
		StyleFunc(func(row, col int) lipgloss.Style {
			if row == table.HeaderRow {
				return headerStyle.Padding(0, 1)
			}
			if col == 0 {
				return idStyle.Padding(0, 1)
			}
			return lipgloss.NewStyle().Padding(0, 1)
		})
	for _, d := range res.Devices {
		t.Row(d.ID, d.Name, d.PairedAt.Format("2006-01-02 15:04"), humanSince(d.LastSeen))
	}
	fmt.Println(t)
	return nil
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
	fmt.Println(okStyle.Render("✓ revoked "+res.Name) +
		hintStyle.Render(" — its bearer no longer authenticates and it will receive no further pushes"))
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
