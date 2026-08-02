package cli

import (
	"context"
	"os"

	"github.com/charmbracelet/log"
	"github.com/spf13/cobra"

	"github.com/dipeshdulal/gothalo/internal/config"
	"github.com/dipeshdulal/gothalo/internal/events"
	"github.com/dipeshdulal/gothalo/internal/herdr"
	"github.com/dipeshdulal/gothalo/internal/notify"
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
	log.SetReportTimestamp(true)
	log.SetTimeFormat("15:04:05")

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
		// Never log the token value; point the operator at the file.
		log.Info("generated admin token", "config", cfg.ConfigPath())
	}

	h := herdr.New()
	st, err := store.Open(cfg.DevicesPath())
	if err != nil {
		return err
	}
	pm := pairing.NewManager()

	var pc *push.Client
	if p, err := push.LoadFile(cfg.Push.ServiceAccountPath); err != nil {
		log.Warn("FCM disabled — notify will log only", "reason", err)
	} else {
		pc = p
		log.Info("FCM enabled", "project", p.ProjectID())
	}

	// The unified event bus and the single process-wide Herdr ingester. Every WS
	// /events client is a bus subscriber; the ingester holds the one Herdr socket
	// subscription and fans it out (never one Herdr connection per client).
	bus := events.New()
	ing := herdr.NewIngester(h, bus)
	go ing.Run(context.Background())

	srv := server.New(cfg, h, pc, st, pm, web.FS(), bus)

	w := watcher.New(h, srv.Notify, os.Getenv("WATCHER") == "poll")
	go w.Run()

	// The notification-clearer is the process-wide bus consumer that dismisses a
	// stale "blocked" push once the pane leaves blocked or closes (from anywhere).
	go notify.NewClearer(bus, pc, st).Run(context.Background())

	var tr transport.Transport
	switch cfg.Transport.Mode {
	case "relay":
		// Not implemented yet; constructed so mode selection is real.
		tr = relay.New(cfg.Transport.PublicURL, "", "")
	default:
		tr = direct.New(cfg.Transport.Addr)
	}

	log.Info("gothalo serve",
		"mode", tr.Name(),
		"addr", cfg.Transport.Addr,
		"public_url", cfg.Transport.PublicURL)
	return tr.Serve(srv.Handler())
}
