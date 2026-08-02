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
	Send(deviceToken, title, body string, data map[string]string) error
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

	mu      sync.Mutex
	pending map[string]struct{} // pane_ids with an outstanding "blocked" push
}

// NewClearer builds a Clearer over the live bus, FCM client, and device store.
// p may be nil (FCM disabled): the consumer then never arms — no push_sent is
// published when FCM is off — and any dismiss degrades to a log line.
func NewClearer(bus *events.Bus, p *push.Client, st *store.Store) *Clearer {
	c := newClearer(bus, nil, st)
	if p != nil { // avoid a typed-nil interface that would defeat the nil check
		c.push = p
	}
	return c
}

// newClearer is the shared constructor used by NewClearer and tests, taking the
// narrow seams directly.
func newClearer(bus *events.Bus, s sender, d devices) *Clearer {
	return &Clearer{bus: bus, push: s, devices: d, pending: map[string]struct{}{}}
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
	// A blocked push just went out: remember the pane until it resolves.
	case env.Source == events.SourceGothalo && env.Type == events.TypePushSent:
		var p struct {
			Agent  string `json:"agent"`
			Status string `json:"status"`
		}
		if json.Unmarshal(env.Payload, &p) == nil && p.Status == "blocked" && p.Agent != "" {
			c.arm(p.Agent)
		}

	// The pane left "blocked" (any other status, incl. idle/working/done/unknown).
	case env.Type == events.TypePaneAgentStatusChanged:
		var p struct {
			PaneID      string `json:"pane_id"`
			AgentStatus string `json:"agent_status"`
		}
		if json.Unmarshal(env.Payload, &p) == nil && p.PaneID != "" &&
			p.AgentStatus != "" && p.AgentStatus != "blocked" {
			c.dismiss(p.PaneID)
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

// arm records a pane as awaiting clear. A pane that flips blocked→working→blocked
// re-arms here on the new blocked push, so the next resolution dismisses again.
func (c *Clearer) arm(pane string) {
	c.mu.Lock()
	c.pending[pane] = struct{}{}
	c.mu.Unlock()
	log.Info("notification-clearer: armed", "pane", pane)
}

// dismiss clears the notification for a pane, but only if it has an outstanding
// blocked push. The pane is removed from the tracker under the lock BEFORE any
// send, so a burst of resolving events dismisses exactly once (no double-dismiss)
// and an unrelated pane is ignored.
func (c *Clearer) dismiss(pane string) {
	c.mu.Lock()
	if _, armed := c.pending[pane]; !armed {
		c.mu.Unlock()
		return // not awaiting clear: unrelated pane, or already dismissed
	}
	delete(c.pending, pane)
	c.mu.Unlock()

	c.fanoutDismiss(pane)

	// Bonus/consistency event: a foreground app can clear its own UI without FCM.
	if _, err := c.bus.Publish(events.SourceGothalo, events.TypeNotificationCleared,
		map[string]string{"pane": pane}); err != nil {
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
	// data-only, no title/body: the app's background handler cancels the tray
	// notification keyed to this pane; "type":"dismiss" is the discriminator.
	data := map[string]string{"type": "dismiss", "agent": pane}
	sent := 0
	for _, t := range tokens {
		if err := c.push.Send(t, "", "", data); err != nil {
			log.Error("notification-clearer: dismiss push failed", "token", t[:min(8, len(t))]+"…", "err", err)
			continue
		}
		sent++
	}
	log.Info("notification-clearer: dismissed", "pane", pane, "sent", sent, "total", len(tokens))
}
