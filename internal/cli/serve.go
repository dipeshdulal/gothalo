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
	if saved, err := cfg.EnsureServerID(); err != nil {
		return err
	} else if saved {
		log.Info("generated server id", "id", cfg.ServerID, "name", cfg.ServerName)
	}

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

	// The unified event bus. Every WS /events client is a bus subscriber; each
	// session's ingester holds that session's one Herdr socket subscription and
	// fans it out (never one Herdr connection per client).
	bus := events.New()

	// One ingester + watcher per running Herdr session, started (and stopped) by
	// the session manager as sessions come and go. Pane ids from non-default
	// sessions are qualified as "<session>/<pane>" everywhere they leave the bridge.
	usePoll := os.Getenv("WATCHER") == "poll"
	var srv *server.Server
	mgr := herdr.NewManager(func(name string, c *herdr.Client) func() {
		ctx, cancel := context.WithCancel(context.Background())
		go herdr.NewIngester(c, bus).Run(ctx)
		w := watcher.New(c, func(paneID, status, title string, seq int) {
			srv.Notify(herdr.Qualify(c.Session(), paneID), status, title, seq)
		}, usePoll)
		go w.Run(ctx)
		return cancel
	})

	srv = server.New(cfg, mgr, pc, st, pm, web.FS(), bus)
	go mgr.Run(context.Background())

	// The notification-clearer is the process-wide bus consumer that dismisses a
	// stale "blocked" push once the pane leaves blocked or closes (from anywhere).
	go notify.NewClearer(bus, pc, st, cfg.ServerID).Run(context.Background())

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
