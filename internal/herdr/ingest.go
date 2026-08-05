package herdr

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/events"
)

// globalSubscriptions is the set of Herdr subscription kinds that need no
// pane_id — the structural events the whole process cares about. The three
// per-pane kinds (pane.agent_status_changed / output_matched / scroll_changed)
// cannot appear here at all: Herdr requires a pane_id for them. Agent status is
// handled by one dedicated connection per pane instead — see
// [Ingester.watchPane]. pane.output_changed is deliberately left out — it is
// high-volume output churn that belongs on the per-pane transcript path, not the
// coarse bus.
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

// probeInterval is how often the ingester checks that its subscription is
// actually delivering. See [Ingester.watchLiveness].
const probeInterval = 30 * time.Second

// probeStrikes is how many consecutive disagreeing probes force a resubscribe.
// Requiring two avoids reconnecting over an event that was merely in flight when
// the first probe read the snapshot.
const probeStrikes = 2

// probeSilence is how long the socket must have delivered NOTHING before a
// disagreeing snapshot is treated as proof the subscription is dead.
//
// Without this gate the probe fires on any busy machine: an agent that is
// actively working flips status between the moment an event is published and
// the moment the snapshot is read, so the two views disagree essentially always
// and the ingester resubscribes in a loop.
const probeSilence = 90 * time.Second

// Ingester owns this session's Herdr event subscriptions: one connection for the
// global structural kinds, plus one dedicated connection per agent pane for its
// agent status (which Herdr only offers per-pane). It normalizes every Herdr
// event into the unified events.Envelope and publishes it to the bus. It owns
// the Herdr connectivity lifecycle: on disconnect it emits gothalo.herdr_disconnected,
// reconnects, re-subscribes, and emits gothalo.herdr_resync so app clients
// re-snapshot to close any gap.
type Ingester struct {
	cli *Client
	bus *events.Bus

	// mu guards lastStatus, which the read loop writes and the liveness probe
	// reads from its own goroutine.
	mu sync.Mutex
	// lastStatus is the last agent_status published per pane, so the several
	// Herdr signals that carry status (the targeted pane.agent_status_changed,
	// plus pane_updated / pane_created / pane_agent_detected) collapse into one
	// deduplicated pane_agent_status_changed envelope per real transition.
	//
	// It doubles as the reference the liveness probe compares Herdr against: it
	// is precisely "what we believe we have told the bus", so disagreement with
	// Herdr's own view means events are going missing.
	lastStatus map[string]string
	// watchMu guards watchers, which the main read loop mutates (on
	// agent_detected / pane closed) while each watcher goroutine runs independently.
	watchMu sync.Mutex
	// watchers maps an agent pane to the cancel for its dedicated agent-status
	// subscription. One connection per agent pane — see [Ingester.watchPane] for
	// why a single shared subscription cannot work.
	watchers map[string]context.CancelFunc
	// lastEventAt is when the socket last delivered anything at all.
	//
	// Disagreement between Herdr's snapshot and what we published is NOT on its
	// own evidence of a dead subscription: the two views are sampled at
	// different instants, so on a busy machine an agent that is mid-transition
	// makes them differ constantly. Only silence turns disagreement into
	// evidence — if nothing has arrived for a while AND the world has moved on
	// without us, the subscription really has stopped delivering.
	lastEventAt time.Time
}

// NewIngester builds an Ingester over the given CLI client and bus.
func NewIngester(cli *Client, bus *events.Bus) *Ingester {
	return &Ingester{cli: cli, bus: bus, lastStatus: map[string]string{},
		watchers: map[string]context.CancelFunc{}}
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
			log.Warn("herdr ingester: session ended", "session", i.cli.SessionLabel(), "err", err)
		}
		i.bus.Publish(events.SourceGothalo, events.TypeHerdrDisconnected,
			map[string]any{"reason": "socket closed", "session": i.cli.SessionLabel()})
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
	seeded := i.seedStatuses()
	subs := i.subscriptionsFor()

	if err := conn.Subscribe(subs); err != nil {
		return err
	}

	// One dedicated agent-status subscription per agent pane. Scoped to ctx (the
	// Ingester's life), not this session, so a main-socket reconnect leaves them
	// alone. ensureWatcher is idempotent, so re-seeding after a reconnect is free.
	for pane := range seeded {
		i.ensureWatcher(ctx, pane)
	}
	log.Info("herdr ingester: subscribed", "session", i.cli.SessionLabel(), "socket", path, "subscriptions", len(subs))

	i.bus.Publish(events.SourceGothalo, events.TypeHerdrConnected,
		map[string]any{"socket": path, "session": i.cli.SessionLabel()})
	if !first {
		// A reconnect may have missed events; tell clients to re-snapshot.
		i.bus.Publish(events.SourceGothalo, events.TypeHerdrResync,
			map[string]any{"reason": "herdr reconnected", "session": i.cli.SessionLabel()})
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
	// Start the silence clock at subscribe, so a fresh session isn't judged
	// against a zero timestamp and declared dead before it has said anything.
	i.sawEvent()
	go i.watchLiveness(sctx, scancel)

	for {
		msg, err := conn.ReadMessage()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		i.handle(ctx, msg)
	}
}

// watchLiveness forces a resubscribe when the subscription stops delivering.
//
// A subscribe can succeed and then deliver nothing — observed after a host
// reboot, where the bridge logged "subscribed, subscriptions=29" and received
// not one event for twenty minutes. Nothing detected it: the read loop simply
// blocks forever on a socket that is open and silent, so the session never ends
// and the reconnect path never runs. Everything downstream (notification
// clearing, WS /events, the app's agent list) then looks broken while every
// component reports itself healthy — which is the worst kind of failure,
// because there is nothing to alert on.
//
// It cannot be a plain silence timer: an idle Herdr is legitimately quiet for
// long stretches, and reconnecting on quiet alone would churn the socket on any
// machine nobody is using. So it probes for DISAGREEMENT instead — Herdr's own
// current agent statuses against what we believe we published. Divergence is
// positive evidence that events are being missed, whereas silence is not
// evidence of anything.
//
// Killing the session context closes the connection, which fails the read loop
// and drops into Run's normal reconnect + resubscribe + herdr_resync path.
func (i *Ingester) watchLiveness(ctx context.Context, kill func()) {
	ticker := time.NewTicker(probeInterval)
	defer ticker.Stop()

	strikes := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if !i.stale() {
				strikes = 0
				continue
			}
			strikes++
			if strikes < probeStrikes {
				continue
			}
			log.Warn("herdr ingester: subscription is not delivering events, resubscribing",
				"session", i.cli.SessionLabel(), "probes", strikes)
			kill()
			return
		}
	}
}

// stale reports whether the subscription has stopped delivering: the socket has
// been silent for a while AND Herdr's live view has moved on without us.
//
// Both halves are required. Silence alone is normal — an idle Herdr says nothing
// for hours. Disagreement alone is normal too — the snapshot and the event
// stream are sampled at different instants, so an agent mid-transition makes
// them differ. Only together do they mean events are being lost.
//
// An unreadable snapshot returns false: we cannot tell, and guessing would
// reconnect a healthy socket.
func (i *Ingester) stale() bool {
	if !i.silentFor(probeSilence) {
		return false
	}
	agents, err := i.cli.Agents()
	if err != nil {
		return false
	}
	return i.staleAgainst(agents)
}

// silentFor reports whether nothing has arrived on the socket for at least d.
func (i *Ingester) silentFor(d time.Duration) bool {
	i.mu.Lock()
	defer i.mu.Unlock()
	return time.Since(i.lastEventAt) >= d
}

// sawEvent records that the socket delivered something.
func (i *Ingester) sawEvent() {
	i.mu.Lock()
	i.lastEventAt = time.Now()
	i.mu.Unlock()
}

// staleAgainst is the comparison itself, split out so it can be exercised
// without a live socket. A pane Herdr knows about that we have never published,
// or one whose status has moved on without us, both mean events went missing.
func (i *Ingester) staleAgainst(agents []Agent) bool {
	i.mu.Lock()
	defer i.mu.Unlock()
	for _, a := range agents {
		if last, seen := i.lastStatus[a.PaneID]; !seen || last != a.Status {
			return true
		}
	}
	return false
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
	i.mu.Lock()
	for _, a := range agents {
		statuses[a.PaneID] = a.Status
		i.lastStatus[a.PaneID] = a.Status
	}
	i.mu.Unlock()
	return statuses
}

// subscriptionsFor builds the main connection's events.subscribe set: the global
// structural kinds only.
//
// Agent status is deliberately NOT here any more. Herdr's
// pane.agent_status_changed is a targeted subscription requiring a pane_id, and
// a connection's subscription set is frozen at connect (its handler reads
// exactly one request line and never parses another). So panes created later
// could never be added, and their status only ever surfaced when some unrelated
// structural event happened to carry it along — measured against the live
// socket: 57 seconds of silence across all 24 global kinds while an agent went
// idle -> working -> blocked.
//
// Every agent pane now gets its own connection instead. See [Ingester.watchPane].
func (i *Ingester) subscriptionsFor() []Subscription {
	subs := make([]Subscription, 0, len(globalSubscriptions))
	return append(subs, globalSubscriptions...)
}

// ensureWatcher starts a dedicated agent-status subscription for a pane, if one
// isn't already running. Idempotent: called both when seeding at connect and on
// every pane.agent_detected.
func (i *Ingester) ensureWatcher(ctx context.Context, pane string) {
	if pane == "" || ctx.Err() != nil {
		return
	}
	i.watchMu.Lock()
	if _, running := i.watchers[pane]; running {
		i.watchMu.Unlock()
		return
	}
	wctx, cancel := context.WithCancel(ctx)
	i.watchers[pane] = cancel
	i.watchMu.Unlock()

	go i.watchPane(wctx, pane)
}

// stopWatcher tears down a pane's subscription when the pane is gone.
func (i *Ingester) stopWatcher(pane string) {
	i.watchMu.Lock()
	cancel, running := i.watchers[pane]
	delete(i.watchers, pane)
	i.watchMu.Unlock()
	if running {
		cancel()
	}
}

// watchPane keeps one pane's agent-status subscription alive until ctx ends.
//
// Deliberately scoped to the Ingester's lifetime rather than the main
// connection's: these are independent sockets, so the main stream reconnecting
// should not churn every pane watcher with it.
func (i *Ingester) watchPane(ctx context.Context, pane string) {
	for {
		if ctx.Err() != nil {
			return
		}
		err := i.paneSession(ctx, pane)
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			// Distinguish "the pane is gone" from "the socket hiccuped", because
			// the first must stop and the second must retry. It matters more than
			// it looks: a connection's global subscriptions replay Herdr's whole
			// event ring on connect, so a fresh session sees pane_created for
			// panes that have since closed and would otherwise start a watcher for
			// each — every one of them then retrying forever, holding a doomed
			// connection and logging on every attempt.
			if _, gerr := i.cli.Get(pane); errors.Is(gerr, ErrAgentNotFound) {
				i.stopWatcher(pane)
				return
			}
			log.Warn("herdr ingester: pane watch ended", "pane", pane, "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(reconnectDelay):
		}
	}
}

// paneSession runs one targeted subscription for one pane.
//
// Worth knowing what Herdr gives us here, because it is better than a raw event
// feed: the subscription falls back to polling that pane and diffing when the
// event hub had nothing, so a missed event still surfaces. That makes these
// self-healing in a way the global structural kinds are not.
//
// It also fires on presentation changes (a terminal title update) as well as
// status ones, so the same status arrives repeatedly — emitAgentStatus dedupes,
// which is why that already exists.
func (i *Ingester) paneSession(ctx context.Context, pane string) error {
	path, err := i.cli.socketPath()
	if err != nil {
		return err
	}
	conn, err := DialSocket(path)
	if err != nil {
		return err
	}
	defer conn.Close()

	if err := conn.Subscribe([]Subscription{
		{Type: "pane.agent_status_changed", PaneID: pane},
	}); err != nil {
		return err
	}

	cctx, ccancel := context.WithCancel(ctx)
	defer ccancel()
	go func() {
		<-cctx.Done()
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
		// Any traffic on any connection is proof the Herdr socket is alive, which
		// is what the liveness probe actually cares about.
		i.sawEvent()
		if msg.Event != "pane.agent_status_changed" {
			continue
		}
		var d struct {
			PaneID      string `json:"pane_id"`
			WorkspaceID string `json:"workspace_id"`
			Agent       string `json:"agent"`
			AgentStatus string `json:"agent_status"`
		}
		if json.Unmarshal(msg.Data, &d) == nil && d.PaneID != "" {
			i.emitAgentStatus(d.PaneID, d.WorkspaceID, d.Agent, d.AgentStatus)
		}
	}
}

// handle maps one decoded socket message to the bus.
func (i *Ingester) handle(ctx context.Context, msg SocketMessage) {
	// Anything at all counts as proof of life, including the acks we don't
	// forward: the liveness probe cares that the socket is delivering, not what.
	i.sawEvent()
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
		// Forward Herdr's event (its data object is the payload), session-tagged.
		i.bus.Publish(events.SourceHerdr, msg.Event, i.tag(msg.Data))
		i.deriveAgentStatus(msg)
		i.trackPaneLifecycle(ctx, msg)
		return
	}

	// Any other (unexpected) event kind is still forwarded so nothing is silently
	// dropped; the app can ignore types it doesn't know.
	i.bus.Publish(events.SourceHerdr, msg.Event, i.tag(msg.Data))
}

// tag decodes a Herdr payload, qualifies its ids with this ingester's session,
// and stamps the session label so bus consumers can tell sessions apart. On a
// decode failure the payload is forwarded untouched.
func (i *Ingester) tag(data json.RawMessage) any {
	var v any
	if json.Unmarshal(data, &v) != nil {
		return data
	}
	QualifyIDs(v, i.cli.Session())
	if obj, ok := v.(map[string]any); ok {
		obj["session"] = i.cli.SessionLabel()
	}
	return v
}

// deriveAgentStatus extracts an agent status from the structural events that
// happen to carry one (pane_updated, pane_created, pane_agent_detected) and
// feeds the deduped emitter. pane_closed/pane_exited clear the pane's baseline.
//
// This is a belt-and-braces path, not the primary one: those events fire on
// structural changes, not on agent transitions, so they cannot be relied on to
// report a status change at all. The per-pane subscriptions
// ([Ingester.watchPane]) are what actually deliver agent status. This just means
// a status that rides along on a structural event is not thrown away.
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
			i.mu.Lock()
			delete(i.lastStatus, d.PaneID)
			i.mu.Unlock()
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
	i.mu.Lock()
	unchanged := i.lastStatus[pane] == status
	if !unchanged {
		i.lastStatus[pane] = status
	}
	i.mu.Unlock()
	if unchanged {
		return
	}
	i.bus.Publish(events.SourceHerdr, events.TypePaneAgentStatusChanged, map[string]any{
		"pane_id":      Qualify(i.cli.Session(), pane),
		"workspace_id": Qualify(i.cli.Session(), workspace),
		"agent":        agent,
		"agent_status": status,
		"session":      i.cli.SessionLabel(),
	})
}

// trackPaneLifecycle opens and closes per-pane agent-status subscriptions as
// agents come and go.
//
// pane.agent_detected is the global signal Herdr provides precisely so a client
// can then subscribe to that pane specifically — the two-step handshake its API
// is shaped around. It is the only way to learn about an agent that appeared
// after we connected, since the main connection's subscription set cannot be
// extended.
func (i *Ingester) trackPaneLifecycle(ctx context.Context, msg SocketMessage) {
	switch msg.Event {
	case events.TypePaneAgentDetected:
		var d struct {
			PaneID string `json:"pane_id"`
		}
		if json.Unmarshal(msg.Data, &d) == nil {
			i.ensureWatcher(ctx, d.PaneID)
		}
	case events.TypePaneCreated, events.TypePaneUpdated:
		// A pane can carry an agent without a detection event having been seen on
		// this connection — e.g. one that already had an agent when it was moved
		// or restored. Watching is idempotent, so covering both is free.
		var d struct {
			Pane struct {
				PaneID string `json:"pane_id"`
				Agent  string `json:"agent"`
			} `json:"pane"`
		}
		if json.Unmarshal(msg.Data, &d) == nil && d.Pane.Agent != "" {
			i.ensureWatcher(ctx, d.Pane.PaneID)
		}
	case events.TypePaneClosed, events.TypePaneExited:
		var d struct {
			PaneID string `json:"pane_id"`
		}
		if json.Unmarshal(msg.Data, &d) == nil {
			i.stopWatcher(d.PaneID)
		}
	}
}
