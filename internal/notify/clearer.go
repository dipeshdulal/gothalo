// Package notify holds the notification-clearer: the first real consumer of the
// gothalo event bus. It dismisses stale "blocked" push notifications.
//
// When an agent blocks, the bridge fans a "blocked" push out to every device
// (server.Notify) and mirrors it as a gothalo.push_sent bus event. The Clearer
// subscribes to the bus, remembers the pane behind each such push, and — when
// the bus shows that pane leaving blocked (herdr.pane_agent_status_changed with
// agent_status != "blocked") or the pane closing (pane_closed / pane_exited) —
// sends a data-only "dismiss" FCM to the same devices and publishes a
// gothalo.notification_cleared event.
//
// Because the resolution is observed on the bus, it works regardless of who
// handled the block (this phone, another device, the desktop Herdr app, or the
// agent simply moving on): the Herdr transition reaches the bus either way.
package notify

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/events"
	"github.com/dipeshdulal/gothalo/internal/push"
	"github.com/dipeshdulal/gothalo/internal/store"
)

// clearerBuffer bounds how far the consumer may fall behind the bus before it is
// dropped and re-subscribes. The bus is coarse and low-volume, so a few hundred
// is generous.
const clearerBuffer = 256

// sweepInterval is how often every outstanding notification is re-checked
// against Herdr, independently of anything arriving on the bus.
//
// The bus cannot be relied on to tell us a notification went stale. Herdr's
// pane.agent_status_changed is a *targeted* subscription requiring a pane_id,
// and a connection's subscription set is frozen at connect — so a pane created
// after the bridge started has no such subscription, and the global structural
// events do not fire on agent status changes (measured: 57s of silence across
// all 24 global kinds while an agent went idle -> working -> blocked). For those
// panes a resolution produces no event at all, and a bus-driven clearer would
// leave the notification in the tray forever.
//
// The sweep costs one read per ARMED pane, and panes are only armed while they
// have an outstanding notification — normally zero, occasionally one or two.
const sweepInterval = 10 * time.Second

// sender is the subset of push.Client the Clearer needs (a seam for tests).
type sender interface {
	SendMessage(push.Message) error
}

// devices is the subset of store.Store the Clearer needs (a seam for tests).
type devices interface {
	FCMTokens() []string
}

// agentReader is an authoritative read of one pane's current agent state.
//
// The Clearer decides whether a notification is still true, and it must not
// answer that from the event bus. The bus is a CHANGE SIGNAL, not a state feed:
// its payload can be coarse (a pane created after the bridge connected has no
// targeted Herdr subscription, so its status is only ever scavenged out of
// structural events), and it is produced by a different observer than the one
// that announced the push. Comparing across those two was the bug this seam
// exists to remove — see [Clearer.arm].
//
// Status and seq come back from ONE read, so they can never be a torn pair.
type agentReader interface {
	AgentState(pane string) (status string, seq int, err error)
}

// Clearer is the process-wide consumer that dismisses stale "blocked" pushes.
// One instance runs for the whole daemon (not one per client). It is safe for
// concurrent use: the tracker is mutex-guarded and the bus fans out from its own
// goroutine.
type Clearer struct {
	bus     *events.Bus
	push    sender  // nil when FCM is disabled -> dismiss logs only
	devices devices // device registry, source of the FCM fan-out target
	// serverID identifies this bridge in the dismiss payload, so a phone paired
	// with several bridges cancels the right machine's notification.
	serverID string

	// agents is the authoritative read. nil disables verification: the Clearer
	// then trusts the bus, which is the pre-seam behaviour and only sane in tests.
	agents agentReader

	mu sync.Mutex
	// pending maps a pane_id to the outstanding push for it. Keeping the status —
	// not just the fact of a push — is what lets a "done" notice survive until the
	// agent actually moves on, instead of being cleared by the very transition
	// that raised it.
	pending map[string]armed
}

// armed is an outstanding notification: what it announced, and the Herdr
// state_change_seq it announced it at.
//
// seq is Herdr's single app-wide counter, so it is a total order over every
// agent transition — the one token that is comparable across observers. It is
// recorded for diagnostics and for the idempotent-approve contract; the dismiss
// decision itself keys off status (see [Clearer.stillTrue]).
type armed struct {
	status string
	seq    int
}

// NewClearer builds a Clearer over the live bus, FCM client, and device store.
// p may be nil (FCM disabled): the consumer then never arms — no push_sent is
// published when FCM is off — and any dismiss degrades to a log line.
func NewClearer(bus *events.Bus, p *push.Client, st *store.Store, serverID string, a agentReader) *Clearer {
	c := newClearer(bus, nil, st, serverID, a)
	if p != nil { // avoid a typed-nil interface that would defeat the nil check
		c.push = p
	}
	return c
}

// newClearer is the shared constructor used by NewClearer and tests, taking the
// narrow seams directly.
func newClearer(bus *events.Bus, s sender, d devices, serverID string, a agentReader) *Clearer {
	return &Clearer{
		bus: bus, push: s, devices: d, serverID: serverID, agents: a,
		pending: map[string]armed{},
	}
}

// Run subscribes to the bus and consumes events until ctx is cancelled. Call it
// in its own goroutine. If the subscription is dropped for lagging it
// re-subscribes; the outstanding-push tracker survives across re-subscribes.
func (c *Clearer) Run(ctx context.Context) {
	log.Info("notification-clearer: started")
	for {
		if ctx.Err() != nil {
			return
		}
		sub := c.bus.Subscribe(clearerBuffer)
		dropped := c.consume(ctx, sub)
		sub.Close()
		if !dropped || ctx.Err() != nil {
			return
		}
		log.Warn("notification-clearer: bus subscription dropped, re-subscribing")
	}
}

// consume reads from one subscription until ctx is cancelled or the channel is
// closed. It reports whether the channel closed because the bus dropped the
// subscriber (lagging), so Run knows to re-subscribe.
func (c *Clearer) consume(ctx context.Context, sub *events.Sub) (dropped bool) {
	ticker := time.NewTicker(sweepInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return false
		case <-ticker.C:
			c.sweep()
		case env, ok := <-sub.C():
			if !ok {
				return sub.Dropped()
			}
			c.handle(env)
		}
	}
}

// sweep re-checks every outstanding notification against Herdr and dismisses the
// ones that are no longer true. It is what makes the Clearer correct without the
// bus: a bus event merely makes a resolution noticed *sooner*. See
// [sweepInterval] for why the bus is not sufficient on its own.
func (c *Clearer) sweep() {
	c.mu.Lock()
	panes := make([]string, 0, len(c.pending))
	for pane := range c.pending {
		panes = append(panes, pane)
	}
	c.mu.Unlock()

	for _, pane := range panes {
		c.dismissUnless(pane)
	}
}

// handle routes one envelope: arm on a blocked push, dismiss on a resolution.
func (c *Clearer) handle(env events.Envelope) {
	switch {
	// A push just went out: remember the pane, and what it announced, until the
	// agent moves on from that state.
	case env.Source == events.SourceGothalo && env.Type == events.TypePushSent:
		var p struct {
			Agent  string `json:"agent"`
			Status string `json:"status"`
			Seq    int    `json:"seq"`
		}
		if json.Unmarshal(env.Payload, &p) == nil && p.Agent != "" &&
			(p.Status == "blocked" || p.Status == "done") {
			c.arm(p.Agent, p.Status, p.Seq)
		}

	// The pane MAY have changed status. Treated purely as a nudge: the payload's
	// own agent_status is deliberately ignored, because it is only as good as the
	// Herdr subscription behind it (a pane created after connect has none, so its
	// status is scavenged out of structural events and can be arbitrarily stale).
	// The decision is made from a fresh read instead.
	case env.Type == events.TypePaneAgentStatusChanged:
		var p struct {
			PaneID string `json:"pane_id"`
		}
		if json.Unmarshal(env.Payload, &p) == nil && p.PaneID != "" {
			c.dismissUnless(p.PaneID)
		}

	// The pane is gone: closed or its process exited (either source).
	case env.Type == events.TypePaneClosed || env.Type == events.TypePaneExited:
		var p struct {
			PaneID string `json:"pane_id"`
		}
		if json.Unmarshal(env.Payload, &p) == nil && p.PaneID != "" {
			c.dismiss(p.PaneID)
		}
	}
}

// stillTrue asks Herdr whether a notification announcing `status` for `pane` is
// still accurate, and returns the pane's current seq alongside.
//
// The second return reports whether we could answer at all. When we could not
// — no reader wired, the pane is gone, Herdr is unreachable — callers must NOT
// dismiss. A notification that lingers slightly too long is a nuisance; one that
// vanishes while the agent is still waiting on you is the failure this whole
// subsystem exists to prevent.
func (c *Clearer) stillTrue(pane, status string) (seq int, known bool, ok bool) {
	if c.agents == nil {
		return 0, false, false
	}
	cur, curSeq, err := c.agents.AgentState(pane)
	if err != nil {
		log.Warn("notification-clearer: state read failed, leaving notification alone",
			"pane", pane, "err", err)
		return 0, false, false
	}
	return curSeq, true, cur == status
}

// arm records a pane as awaiting clear, along with what its notification
// announced. A pane that flips blocked→working→blocked re-arms here on the new
// blocked push, so the next resolution dismisses again.
//
// A push can be overtaken in flight: composing one costs several Herdr reads, so
// the agent may move on before the FCM fan-out finishes. Arming such a push
// strands it — the resolving transition already came and went while the pane was
// unarmed, and nothing will ever clear it.
//
// Detecting that requires knowing the pane's state NOW. An earlier version
// compared against the last status seen on the bus, which was wrong in a way
// worth recording: the bus status and the push announcement are produced by two
// independent observers of Herdr (the ingester's socket subscription and the
// watcher's `agent wait`) with no ordering relation between them. "My record
// disagrees with the push" therefore could not distinguish *the agent moved on*
// from *my record has not caught up* — and for a pane created after the bridge
// connected, the latter is the systematic case, so every blocked push was
// dismissed within the same second it was sent.
//
// A fresh read has no such ambiguity.
func (c *Clearer) arm(pane, status string, seq int) {
	curSeq, known, matches := c.stillTrue(pane, status)
	if known && !matches {
		c.mu.Lock()
		delete(c.pending, pane)
		c.mu.Unlock()
		log.Info("notification-clearer: push overtaken, dismissing",
			"pane", pane, "announced", status, "announced_seq", seq, "current_seq", curSeq)
		c.fanoutDismiss(pane)
		c.publishCleared(pane)
		return
	}

	// Record the seq we actually observed when we could; it is fresher than the
	// one the push announced, and a re-entry into the same state (blocked →
	// working → blocked before we armed) is not a reason to dismiss: the
	// notification says "needs you", which is still true. The newer push shares
	// the notification tag and replaces its contents anyway.
	if !known {
		curSeq = seq
	}
	c.mu.Lock()
	c.pending[pane] = armed{status: status, seq: curSeq}
	c.mu.Unlock()
	log.Info("notification-clearer: armed", "pane", pane, "status", status, "seq", curSeq)
}

// dismissUnless clears the pane's notification unless the pane is still in the
// state that notification announced. The triggering event is only a nudge; the
// answer comes from a fresh read.
func (c *Clearer) dismissUnless(pane string) {
	c.mu.Lock()
	a, ok := c.pending[pane]
	c.mu.Unlock()
	if !ok {
		return // unrelated pane, or already dismissed
	}

	curSeq, known, matches := c.stillTrue(pane, a.status)
	if !known || matches {
		return // can't tell, or still in the announced state — leave it alone
	}

	c.mu.Lock()
	if _, still := c.pending[pane]; !still {
		c.mu.Unlock()
		return // raced with another dismiss; that one owns the send
	}
	delete(c.pending, pane)
	c.mu.Unlock()

	log.Info("notification-clearer: resolved, dismissing",
		"pane", pane, "announced", a.status, "announced_seq", a.seq, "current_seq", curSeq)
	c.fanoutDismiss(pane)
	c.publishCleared(pane)
}

// dismiss clears the notification for a pane whatever state it was announcing —
// used when the pane itself is gone. The pane is removed from the tracker under
// the lock BEFORE any send, so a burst of resolving events dismisses exactly once
// (no double-dismiss) and an unrelated pane is ignored.
func (c *Clearer) dismiss(pane string) {
	c.mu.Lock()
	if _, armed := c.pending[pane]; !armed {
		c.mu.Unlock()
		return // not awaiting clear: unrelated pane, or already dismissed
	}
	delete(c.pending, pane)
	c.mu.Unlock()

	c.fanoutDismiss(pane)
	c.publishCleared(pane)
}

// publishCleared mirrors a dismiss onto the bus, so a foreground app can clear
// its own UI without waiting on FCM.
func (c *Clearer) publishCleared(pane string) {
	if _, err := c.bus.Publish(events.SourceGothalo, events.TypeNotificationCleared,
		map[string]string{"pane": pane, "server_id": c.serverID}); err != nil {
		log.Error("notification-clearer: publish notification_cleared failed", "pane", pane, "err", err)
	}
}

// fanoutDismiss sends the data-only "dismiss" message to every registered device.
// It mirrors server.Notify's degradation: no FCM client -> log only.
func (c *Clearer) fanoutDismiss(pane string) {
	if c.push == nil {
		log.Info("notification-clearer: FCM disabled, dismiss logged only", "pane", pane)
		return
	}
	tokens := c.devices.FCMTokens()
	if len(tokens) == 0 {
		log.Info("notification-clearer: no devices, dismiss skipped", "pane", pane)
		return
	}
	// Silent and data-only: this message exists to make the client cancel the
	// notification keyed to this pane, and must never draw one of its own.
	// "type":"dismiss" is the discriminator; server_id scopes it to this bridge,
	// since the same pane id can exist on another machine the phone is paired to.
	data := map[string]string{"type": "dismiss", "agent": pane, "server_id": c.serverID}
	tag := c.serverID + "/" + pane
	sent := 0
	for _, t := range tokens {
		err := c.push.SendMessage(push.Message{
			Token: t, Kind: push.KindData, Tag: tag, HighPriority: true, Data: data,
		})
		if err != nil {
			log.Error("notification-clearer: dismiss push failed", "token", t[:min(8, len(t))]+"…", "err", err)
			continue
		}
		sent++
	}
	log.Info("notification-clearer: dismissed", "pane", pane, "sent", sent, "total", len(tokens))
}
