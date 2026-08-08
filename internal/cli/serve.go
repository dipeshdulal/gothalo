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
	"github.com/dipeshdulal/gothalo/internal/timeline"
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
	if p, err := push.Resolve(cfg.Push.ServiceAccountPath, cfg.Push.ProjectID); err != nil {
		// A fresh install has no credentials and that is fine — the bridge runs
		// fully without push. Point at the fix rather than just the failure.
		log.Warn("FCM disabled — notify will log only",
			"reason", err, "fix", "run `gothalo push login`, or `gothalo push status` to diagnose")
	} else {
		pc = p
		log.Info("FCM enabled", "project", p.ProjectID(), "credentials", p.Source())
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

	// The recorded agent-activity ring. Loaded before the server so GET /timeline
	// can answer from the persisted history immediately, without waiting for the
	// recorder's first bus event.
	tl := timeline.Open(cfg.TimelinePath())

	// GOTHALO_WEB_DIR serves the static site from a directory instead of the
	// embedded assets. It exists so a web UI can be iterated on without
	// rebuilding the bridge — and, more importantly, so a browser client is
	// served from the BRIDGE'S OWN ORIGIN. Same origin means no CORS on the API
	// and no mixed-content rules to satisfy; a UI hosted anywhere else needs both.
	webFS := web.FS()
	if dir := os.Getenv("GOTHALO_WEB_DIR"); dir != "" {
		webFS = os.DirFS(dir)
		log.Info("serving web from directory", "dir", dir)
	}

	srv = server.New(cfg, mgr, pc, st, pm, webFS, bus, tl)
	// The Server owns real listeners beyond the HTTP one (preview relays), so it
	// gets released rather than left to process exit — which matters for the
	// tests and for anything that ever restarts it in-process.
	defer srv.Close()
	go mgr.Run(context.Background())

	// The notification-clearer is the process-wide bus consumer that dismisses a
	// stale "blocked" push once the pane leaves blocked or closes (from anywhere).
	// It takes an authoritative reader rather than trusting the bus payload: the
	// bus is a change signal, and its status can be stale or coarse depending on
	// which Herdr subscription (if any) covers that pane.
	go notify.NewClearer(bus, pc, st, cfg.ServerID, agentReader{mgr}).Run(context.Background())

	// The timeline recorder is the second process-wide bus consumer: it turns the
	// same agent transitions into a bounded, persistent history, so the app can
	// answer "how long has this been blocked" — which no live-state read can. It
	// takes the same authoritative reader, but only to rebuild the open spans it
	// measures durations from (at startup, and whenever Herdr reconnects); the
	// transitions themselves come from the bus.
	go timeline.NewRecorder(tl, bus, agentReader{mgr}).Run(context.Background())

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

// agentReader adapts the Herdr session manager to the narrow read the
// notification-clearer needs. It resolves a session-qualified pane id the same
// way every other bridge caller does, then makes ONE `agent get`, so the status
// and the seq it returns always describe the same instant.
type agentReader struct{ mgr *herdr.Manager }

func (a agentReader) AgentState(pane string) (string, int, error) {
	session, bare := herdr.SplitTarget(pane)
	c, err := a.mgr.Client(session)
	if err != nil {
		return "", 0, err
	}
	agent, err := c.Get(bare)
	if err != nil {
		return "", 0, err
	}
	return agent.Status, agent.StateChangeSeq, nil
}

// Agents lists every agent pane across every Herdr session with its current
// status, for the timeline recorder's post-restart span rebuild. Same walk as
// Announcing, unfiltered: a span is open for every agent, not only the ones
// worth notifying about.
func (a agentReader) Agents() ([]timeline.PaneState, error) {
	var out []timeline.PaneState
	var lastErr error
	for _, name := range a.mgr.Names() {
		c, err := a.mgr.Client(name)
		if err != nil {
			lastErr = err
			continue
		}
		agents, err := c.Agents()
		if err != nil {
			lastErr = err
			continue
		}
		for _, ag := range agents {
			out = append(out, timeline.PaneState{
				Pane:      herdr.Qualify(c.Session(), ag.PaneID),
				Agent:     ag.Kind,
				Session:   c.SessionLabel(),
				Workspace: herdr.Qualify(c.Session(), ag.Workspace),
				Status:    ag.Status,
				Title:     ag.Title,
			})
		}
	}
	if out == nil && lastErr != nil {
		return nil, lastErr
	}
	return out, nil
}

// Announcing lists every agent, across every Herdr session, currently in a state
// the bridge notifies about. Pane ids are session-qualified exactly as Notify
// qualifies them, so the clearer's keys match the ones its pushes were tagged
// with.
func (a agentReader) Announcing() ([]notify.PaneState, error) {
	var out []notify.PaneState
	var lastErr error
	for _, name := range a.mgr.Names() {
		c, err := a.mgr.Client(name)
		if err != nil {
			lastErr = err
			continue
		}
		agents, err := c.Agents()
		if err != nil {
			lastErr = err
			continue
		}
		for _, ag := range agents {
			if ag.Status != "blocked" && ag.Status != "done" {
				continue
			}
			out = append(out, notify.PaneState{
				Pane:   herdr.Qualify(c.Session(), ag.PaneID),
				Status: ag.Status,
				Seq:    ag.StateChangeSeq,
			})
		}
	}
	// A partial answer is still worth arming: one unreachable session should not
	// cost us the panes we did learn about.
	if out == nil && lastErr != nil {
		return nil, lastErr
	}
	return out, nil
}
