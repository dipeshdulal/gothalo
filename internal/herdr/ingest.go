package herdr

import (
	"context"
	"encoding/json"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/events"
)

// globalSubscriptions is the set of Herdr subscription kinds that need no
// pane_id — the structural events the whole process cares about. Per-pane kinds
// (pane.agent_status_changed / output_matched / scroll_changed) are NOT here;
// only pane.agent_status_changed is added, targeted, for the agent panes present
// at connect (see subscriptionsFor). pane.output_changed has no global
// subscription and is deliberately left out — it is high-volume output churn
// that belongs on the per-pane transcript path, not the coarse bus.
var globalSubscriptions = []Subscription{
	{Type: "workspace.created"}, {Type: "workspace.updated"}, {Type: "workspace.metadata_updated"},
	{Type: "workspace.renamed"}, {Type: "workspace.moved"}, {Type: "workspace.closed"}, {Type: "workspace.focused"},
	{Type: "worktree.created"}, {Type: "worktree.opened"}, {Type: "worktree.removed"},
	{Type: "tab.created"}, {Type: "tab.closed"}, {Type: "tab.renamed"}, {Type: "tab.moved"}, {Type: "tab.focused"},
	{Type: "pane.created"}, {Type: "pane.closed"}, {Type: "pane.updated"}, {Type: "pane.focused"},
	{Type: "pane.moved"}, {Type: "pane.exited"}, {Type: "pane.agent_detected"},
	{Type: "layout.updated"},
}

// globalEventKinds is the set of underscore EventKinds forwarded verbatim onto
// the bus (Herdr's `data` object becomes the envelope payload). The derived
// pane_agent_status_changed is synthesized separately (not forwarded verbatim,
// because Herdr emits it only as the dotted targeted subscription event).
var globalEventKinds = map[string]bool{
	events.TypeWorkspaceCreated: true, events.TypeWorkspaceUpdated: true, events.TypeWorkspaceMetadataUpdated: true,
	events.TypeWorkspaceClosed: true, events.TypeWorkspaceRenamed: true, events.TypeWorkspaceMoved: true, events.TypeWorkspaceFocused: true,
	events.TypeWorktreeCreated: true, events.TypeWorktreeOpened: true, events.TypeWorktreeRemoved: true,
	events.TypeTabCreated: true, events.TypeTabClosed: true, events.TypeTabRenamed: true, events.TypeTabMoved: true, events.TypeTabFocused: true,
	events.TypePaneCreated: true, events.TypePaneClosed: true, events.TypePaneUpdated: true, events.TypePaneFocused: true,
	events.TypePaneMoved: true, events.TypePaneExited: true, events.TypePaneAgentDetected: true,
	events.TypeLayoutUpdated: true,
}

// reconnectDelay is how long the ingester waits before re-dialing a dropped
// Herdr socket.
const reconnectDelay = 2 * time.Second

// Ingester runs the single, process-wide Herdr event subscription: it dials the
// control socket, subscribes once (global structural kinds + targeted
// agent-status for the agent panes present at connect), normalizes every Herdr
// event into the unified events.Envelope, and publishes it to the bus. It owns
// the Herdr connectivity lifecycle: on disconnect it emits gothalo.herdr_disconnected,
// reconnects, re-subscribes, and emits gothalo.herdr_resync so app clients
// re-snapshot to close any gap.
type Ingester struct {
	cli *Client
	bus *events.Bus

	// lastStatus is the last agent_status published per pane, so the several
	// Herdr signals that carry status (the targeted pane.agent_status_changed,
	// plus pane_updated / pane_created / pane_agent_detected) collapse into one
	// deduplicated pane_agent_status_changed envelope per real transition.
	lastStatus map[string]string
}

// NewIngester builds an Ingester over the given CLI client and bus.
func NewIngester(cli *Client, bus *events.Bus) *Ingester {
	return &Ingester{cli: cli, bus: bus, lastStatus: map[string]string{}}
}

// Run drives the connect→subscribe→stream→reconnect loop until ctx is cancelled.
// Call it in its own goroutine.
func (i *Ingester) Run(ctx context.Context) {
	first := true
	for {
		if ctx.Err() != nil {
			return
		}
		if err := i.session(ctx, first); err != nil {
			log.Warn("herdr ingester: session ended", "err", err)
		}
		i.bus.Publish(events.SourceGothalo, events.TypeHerdrDisconnected, map[string]any{"reason": "socket closed"})
		first = false
		select {
		case <-ctx.Done():
			return
		case <-time.After(reconnectDelay):
		}
	}
}

// session runs one full connection: resolve + dial + subscribe + read loop. It
// returns when the connection ends (error or ctx cancel). reconnect is false on
// the very first session (no resync needed) and true thereafter.
func (i *Ingester) session(ctx context.Context, first bool) error {
	path, err := i.cli.ServerSocketPath()
	if err != nil {
		return err
	}
	conn, err := DialSocket(path)
	if err != nil {
		return err
	}
	defer conn.Close()

	// Seed per-pane status from the current snapshot so we don't emit spurious
	// "changes" for state that already holds, and build targeted agent-status
	// subscriptions for those panes.
	subs := i.subscriptionsFor(i.seedStatuses())

	if err := conn.Subscribe(subs); err != nil {
		return err
	}
	log.Info("herdr ingester: subscribed", "socket", path, "subscriptions", len(subs))

	i.bus.Publish(events.SourceGothalo, events.TypeHerdrConnected, map[string]any{"socket": path})
	if !first {
		// A reconnect may have missed events; tell clients to re-snapshot.
		i.bus.Publish(events.SourceGothalo, events.TypeHerdrResync, map[string]any{"reason": "herdr reconnected"})
	}

	// Stop the read loop when ctx is cancelled by closing the connection. The
	// watcher is scoped to THIS session (scancel on return) so a reconnect doesn't
	// leak one blocked goroutine per session.
	sctx, scancel := context.WithCancel(ctx)
	defer scancel()
	go func() {
		<-sctx.Done()
		conn.Close()
	}()

	for {
		msg, err := conn.ReadMessage()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		i.handle(msg)
	}
}

// seedStatuses returns the current agent pane -> status map from a snapshot and
// records it as the dedup baseline. A snapshot failure is non-fatal (returns an
// empty map); the read loop still works, just without a pre-seeded baseline.
func (i *Ingester) seedStatuses() map[string]string {
	statuses := map[string]string{}
	agents, err := i.cli.Agents()
	if err != nil {
		log.Warn("herdr ingester: snapshot for seed failed", "err", err)
		return statuses
	}
	for _, a := range agents {
		statuses[a.PaneID] = a.Status
		i.lastStatus[a.PaneID] = a.Status
	}
	return statuses
}

// subscriptionsFor builds the events.subscribe set: the global structural kinds
// plus a targeted pane.agent_status_changed for each known agent pane.
func (i *Ingester) subscriptionsFor(agentPanes map[string]string) []Subscription {
	subs := make([]Subscription, 0, len(globalSubscriptions)+len(agentPanes))
	subs = append(subs, globalSubscriptions...)
	for pane := range agentPanes {
		subs = append(subs, Subscription{Type: "pane.agent_status_changed", PaneID: pane})
	}
	return subs
}

// handle maps one decoded socket message to the bus.
func (i *Ingester) handle(msg SocketMessage) {
	if msg.Event == "" {
		return // an ack/error line in the stream; nothing to forward
	}

	// The targeted subscription event (dotted) is the precise agent-status
	// signal for panes known at connect. Synthesize the normalized underscore
	// envelope from it rather than forwarding it verbatim.
	if msg.Event == "pane.agent_status_changed" {
		var d struct {
			PaneID      string `json:"pane_id"`
			WorkspaceID string `json:"workspace_id"`
			Agent       string `json:"agent"`
			AgentStatus string `json:"agent_status"`
		}
		_ = json.Unmarshal(msg.Data, &d)
		i.emitAgentStatus(d.PaneID, d.WorkspaceID, d.Agent, d.AgentStatus)
		return
	}

	if globalEventKinds[msg.Event] {
		// Forward Herdr's event verbatim (its data object is the payload).
		i.bus.Publish(events.SourceHerdr, msg.Event, msg.Data)
		i.deriveAgentStatus(msg)
		return
	}

	// Any other (unexpected) event kind is still forwarded so nothing is silently
	// dropped; the app can ignore types it doesn't know.
	i.bus.Publish(events.SourceHerdr, msg.Event, msg.Data)
}

// deriveAgentStatus extracts an agent status from the structural events that
// carry one (pane_updated, pane_created, pane_agent_detected) and feeds the
// deduped emitter. pane_closed/pane_exited clear the pane's baseline. This is the
// catch-all that covers agent panes created AFTER connect (which have no targeted
// subscription), since one events.subscribe per connection can't be extended.
func (i *Ingester) deriveAgentStatus(msg SocketMessage) {
	switch msg.Event {
	case events.TypePaneUpdated, events.TypePaneCreated:
		var d struct {
			Pane struct {
				PaneID      string `json:"pane_id"`
				WorkspaceID string `json:"workspace_id"`
				Agent       string `json:"agent"`
				AgentStatus string `json:"agent_status"`
			} `json:"pane"`
		}
		if json.Unmarshal(msg.Data, &d) == nil && d.Pane.Agent != "" {
			i.emitAgentStatus(d.Pane.PaneID, d.Pane.WorkspaceID, d.Pane.Agent, d.Pane.AgentStatus)
		}
	case events.TypePaneAgentDetected:
		var d struct {
			PaneID      string `json:"pane_id"`
			WorkspaceID string `json:"workspace_id"`
			Agent       string `json:"agent"`
			FinalStatus string `json:"final_status"`
		}
		if json.Unmarshal(msg.Data, &d) == nil {
			i.emitAgentStatus(d.PaneID, d.WorkspaceID, d.Agent, d.FinalStatus)
		}
	case events.TypePaneClosed, events.TypePaneExited:
		var d struct {
			PaneID string `json:"pane_id"`
		}
		if json.Unmarshal(msg.Data, &d) == nil {
			delete(i.lastStatus, d.PaneID)
		}
	}
}

// emitAgentStatus publishes a normalized pane_agent_status_changed envelope, but
// only when the status actually changed for that pane (dedup across the several
// source signals). Herdr's event does not carry state_change_seq, so the app
// pairs the pane with /snapshot to get the seq for /approve.
func (i *Ingester) emitAgentStatus(pane, workspace, agent, status string) {
	if pane == "" || status == "" {
		return
	}
	if i.lastStatus[pane] == status {
		return
	}
	i.lastStatus[pane] = status
	i.bus.Publish(events.SourceHerdr, events.TypePaneAgentStatusChanged, map[string]any{
		"pane_id":      pane,
		"workspace_id": workspace,
		"agent":        agent,
		"agent_status": status,
	})
}
