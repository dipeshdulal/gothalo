package cli

import (
	"log"
	"os"

	"github.com/spf13/cobra"

	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/pairing"
	"github.com/dipeshdulal/gothalo/internal/push"
	"github.com/dipeshdulal/gothalo/internal/server"
	"github.com/dipeshdulal/gothalo/internal/store"
	"github.com/dipeshdulal/gothalo/internal/transport"
	"github.com/dipeshdulal/gothalo/internal/transport/direct"
	"github.com/dipeshdulal/gothalo/internal/transport/relay"
	"github.com/dipeshdulal/gothalo/internal/watcher"
	"github.com/dipeshdulal/gothalo/internal/web"
)

func newServeCmd() *cobra.Command {
	var configPath string
	cmd := &cobra.Command{
		Use:   "serve",
		Short: "Run the bridge daemon",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runServe(configPath)
		},
	}
	cmd.Flags().StringVarP(&configPath, "config", "c", "", "path to config file (default ~/.gothalo/config.json)")
	return cmd
}

func runServe(configPath string) error {
	cfg, err := config.Load(configPath)
	if err != nil {
		return err
	}
	if err := cfg.EnsureDataDir(); err != nil {
		return err
	}
	if saved, err := cfg.EnsureAdminToken(); err != nil {
		return err
	} else if saved {
		log.Printf("generated admin token -> %s", cfg.ConfigPath())
	}

	h := herdr.New()
	st, err := store.Open(cfg.DevicesPath())
	if err != nil {
		return err
	}
	pm := pairing.NewManager()

	var pc *push.Client
	if p, err := push.LoadFile(cfg.Push.ServiceAccountPath); err != nil {
		log.Printf("FCM disabled: %v (notify logs only)", err)
	} else {
		pc = p
		log.Printf("FCM enabled: project=%s", p.ProjectID())
	}

	srv := server.New(cfg, h, pc, st, pm, web.FS())

	w := watcher.New(h, srv.Notify, os.Getenv("WATCHER") == "poll")
	go w.Run()

	var tr transport.Transport
	switch cfg.Transport.Mode {
	case "relay":
		// Not implemented yet; constructed so mode selection is real.
		tr = relay.New(cfg.Transport.PublicURL, "", "")
	default:
		tr = direct.New(cfg.Transport.Addr)
	}

	log.Printf("gothalo serve: mode=%s addr=%s public_url=%q admin_token=%s",
		tr.Name(), cfg.Transport.Addr, cfg.Transport.PublicURL, cfg.AdminToken)
	return tr.Serve(srv.Handler())
}
