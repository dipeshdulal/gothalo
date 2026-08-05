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

	"github.com/charmbracelet/log"

	"github.com/dipeshdulal/gothalo/internal/events"
	"github.com/dipeshdulal/gothalo/internal/push"
	"github.com/dipeshdulal/gothalo/internal/store"
)

// clearerBuffer bounds how far the consumer may fall behind the bus before it is
// dropped and re-subscribes. The bus is coarse and low-volume, so a few hundred
// is generous.
const clearerBuffer = 256

// sender is the subset of push.Client the Clearer needs (a seam for tests).
type sender interface {
	SendMessage(push.Message) error
}

// devices is the subset of store.Store the Clearer needs (a seam for tests).
type devices interface {
	FCMTokens() []string
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

	mu sync.Mutex
	// pending maps a pane_id to the status its outstanding push announced
	// ("blocked" or "done"). Keeping the status — not just the fact of a push —
	// is what lets a "done" notice survive until the agent actually moves on,
	// instead of being cleared by the very transition that raised it.
	pending map[string]string
	// lastStatus is the most recent status seen on the bus for a pane, tracked
	// for EVERY pane whether or not it has an outstanding push.
	//
	// It exists because the two signals race. A status change travels the fast
	// path (Herdr socket -> bus), while a push_sent only lands after the watcher
	// has noticed the transition, read the agent's prompt, and finished the FCM
	// fan-out — seconds later. Answer a prompt quickly and the resolving
	// "working" event arrives BEFORE the "blocked" push it resolves: the pane
	// isn't armed yet, the resolution is dropped, and the notification then sits
	// armed forever waiting for a transition that already happened.
	//
	// Comparing against the last observed status at arm time makes the outcome
	// independent of which order the two arrive in.
	lastStatus map[string]string
}

// NewClearer builds a Clearer over the live bus, FCM client, and device store.
// p may be nil (FCM disabled): the consumer then never arms — no push_sent is
// published when FCM is off — and any dismiss degrades to a log line.
func NewClearer(bus *events.Bus, p *push.Client, st *store.Store, serverID string) *Clearer {
	c := newClearer(bus, nil, st, serverID)
	if p != nil { // avoid a typed-nil interface that would defeat the nil check
		c.push = p
	}
	return c
}

// newClearer is the shared constructor used by NewClearer and tests, taking the
// narrow seams directly.
func newClearer(bus *events.Bus, s sender, d devices, serverID string) *Clearer {
	return &Clearer{
		bus: bus, push: s, devices: d, serverID: serverID,
		pending:    map[string]string{},
		lastStatus: map[string]string{},
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
	for {
		select {
		case <-ctx.Done():
			return false
		case env, ok := <-sub.C():
			if !ok {
				return sub.Dropped()
			}
			c.handle(env)
		}
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
		}
		if json.Unmarshal(env.Payload, &p) == nil && p.Agent != "" &&
			(p.Status == "blocked" || p.Status == "done") {
			c.arm(p.Agent, p.Status)
		}

	// The pane changed status. Dismiss only when it left the state its
	// notification is about: a "done" notice is still true while the agent sits
	// in done, and only becomes stale once it starts working again.
	case env.Type == events.TypePaneAgentStatusChanged:
		var p struct {
			PaneID      string `json:"pane_id"`
			AgentStatus string `json:"agent_status"`
		}
		if json.Unmarshal(env.Payload, &p) == nil && p.PaneID != "" && p.AgentStatus != "" {
			c.observe(p.PaneID, p.AgentStatus)
			c.dismissUnless(p.PaneID, p.AgentStatus)
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

// observe records the latest status seen for a pane, armed or not. See
// [Clearer.lastStatus] for why this is tracked for every pane.
func (c *Clearer) observe(pane, status string) {
	c.mu.Lock()
	c.lastStatus[pane] = status
	c.mu.Unlock()
}

// arm records a pane as awaiting clear, along with the status its notification
// announced. A pane that flips blocked→working→blocked re-arms here on the new
// blocked push, so the next resolution dismisses again.
//
// If the pane has ALREADY been seen in a different state than the one this push
// announces, the push was overtaken in flight — the agent moved on while the
// notification was still being composed and sent. Arming would strand it, so it
// is dismissed straight away instead.
func (c *Clearer) arm(pane, status string) {
	c.mu.Lock()
	last, seen := c.lastStatus[pane]
	stale := seen && last != status
	if stale {
		delete(c.pending, pane)
	} else {
		c.pending[pane] = status
	}
	c.mu.Unlock()

	if stale {
		log.Info("notification-clearer: push overtaken, dismissing",
			"pane", pane, "announced", status, "current", last)
		c.fanoutDismiss(pane)
		c.publishCleared(pane)
		return
	}
	log.Info("notification-clearer: armed", "pane", pane, "status", status)
}

// dismissUnless clears the pane's notification unless the pane is still in the
// state that notification announced.
func (c *Clearer) dismissUnless(pane, status string) {
	c.mu.Lock()
	armed, ok := c.pending[pane]
	if !ok || armed == status {
		c.mu.Unlock()
		return // unrelated pane, already dismissed, or still in the announced state
	}
	delete(c.pending, pane)
	c.mu.Unlock()

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
