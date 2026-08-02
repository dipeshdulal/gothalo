package notify

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/dipeshdulal/gothalo/internal/events"
)

// fakeSender records every dismiss send so a test can assert the exact payload
// and count.
type fakeSender struct {
	mu    sync.Mutex
	sends []map[string]string
}

func (f *fakeSender) Send(token, title, body string, data map[string]string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	cp := map[string]string{"__token": token, "__title": title, "__body": body}
	for k, v := range data {
		cp[k] = v
	}
	f.sends = append(f.sends, cp)
	return nil
}

func (f *fakeSender) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.sends)
}

func (f *fakeSender) last() map[string]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.sends) == 0 {
		return nil
	}
	return f.sends[len(f.sends)-1]
}

// fakeDevices is a fixed device set.
type fakeDevices []string

func (d fakeDevices) FCMTokens() []string { return d }

func raw(t *testing.T, v any) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}

func blockedPush(t *testing.T, pane string) events.Envelope {
	return events.Envelope{Source: events.SourceGothalo, Type: events.TypePushSent,
		Payload: raw(t, map[string]any{"agent": pane, "status": "blocked"})}
}

func statusChange(t *testing.T, pane, status string) events.Envelope {
	return events.Envelope{Source: events.SourceHerdr, Type: events.TypePaneAgentStatusChanged,
		Payload: raw(t, map[string]any{"pane_id": pane, "agent_status": status})}
}

func paneExited(t *testing.T, pane string) events.Envelope {
	return events.Envelope{Source: events.SourceHerdr, Type: events.TypePaneExited,
		Payload: raw(t, map[string]any{"pane_id": pane})}
}

// waitCleared reads one notification_cleared envelope off sub, returning its pane.
func waitCleared(t *testing.T, sub *events.Sub) string {
	t.Helper()
	timeout := time.After(time.Second)
	for {
		select {
		case e, ok := <-sub.C():
			if !ok {
				t.Fatal("bus subscription closed")
			}
			if e.Source == events.SourceGothalo && e.Type == events.TypeNotificationCleared {
				var p struct {
					Pane string `json:"pane"`
				}
				if err := json.Unmarshal(e.Payload, &p); err != nil {
					t.Fatalf("unmarshal notification_cleared: %v", err)
				}
				return p.Pane
			}
		case <-timeout:
			t.Fatal("timed out waiting for notification_cleared")
		}
	}
}

// assertNoCleared fails if any notification_cleared arrives within a short window.
func assertNoCleared(t *testing.T, sub *events.Sub) {
	t.Helper()
	timeout := time.After(100 * time.Millisecond)
	for {
		select {
		case e, ok := <-sub.C():
			if !ok {
				t.Fatal("bus subscription closed")
			}
			if e.Source == events.SourceGothalo && e.Type == events.TypeNotificationCleared {
				t.Fatalf("unexpected notification_cleared for pane %s", e.Payload)
			}
		case <-timeout:
			return
		}
	}
}

// TestArmThenDismiss: a blocked push arms the pane; the resolving status change
// dismisses it (data-only "dismiss" to every device) and publishes
// notification_cleared. A repeat of the same resolution does NOT dismiss again.
func TestArmThenDismiss(t *testing.T) {
	bus := events.New()
	send := &fakeSender{}
	c := newClearer(bus, send, fakeDevices{"tokA", "tokB"})

	sub := bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p2"
	c.handle(blockedPush(t, pane))
	c.handle(statusChange(t, pane, "idle"))

	if got := send.count(); got != 2 {
		t.Fatalf("dismiss sends = %d, want 2 (one per device)", got)
	}
	last := send.last()
	if last["type"] != "dismiss" || last["agent"] != pane {
		t.Errorf("dismiss data = %v, want type=dismiss agent=%s", last, pane)
	}
	if last["__title"] != "" || last["__body"] != "" {
		t.Errorf("dismiss must be data-only, got title=%q body=%q", last["__title"], last["__body"])
	}
	if cleared := waitCleared(t, sub); cleared != pane {
		t.Errorf("notification_cleared pane = %q, want %q", cleared, pane)
	}

	// No double-dismiss: the pane was removed from the tracker on first resolve.
	c.handle(statusChange(t, pane, "working"))
	if got := send.count(); got != 2 {
		t.Errorf("after second resolution sends = %d, want still 2 (no double-dismiss)", got)
	}
	assertNoCleared(t, sub)
}

// TestReArmOnNewBlock: after a dismiss, a fresh blocked push re-arms the pane so
// the next resolution dismisses again.
func TestReArmOnNewBlock(t *testing.T) {
	bus := events.New()
	send := &fakeSender{}
	c := newClearer(bus, send, fakeDevices{"tokA"})
	sub := bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p2"
	c.handle(blockedPush(t, pane))
	c.handle(statusChange(t, pane, "working"))
	if send.count() != 1 {
		t.Fatalf("first dismiss sends = %d, want 1", send.count())
	}
	_ = waitCleared(t, sub)

	// Re-arm on a new block, then close the pane -> dismiss again.
	c.handle(blockedPush(t, pane))
	c.handle(paneExited(t, pane))
	if send.count() != 2 {
		t.Fatalf("after re-arm dismiss sends = %d, want 2", send.count())
	}
	if got := waitCleared(t, sub); got != pane {
		t.Errorf("second notification_cleared pane = %q, want %q", got, pane)
	}
}

// TestUnarmedResolutionIgnored: a resolution for a pane that never had a blocked
// push (or a "blocked" status change itself) triggers nothing.
func TestUnarmedResolutionIgnored(t *testing.T) {
	bus := events.New()
	send := &fakeSender{}
	c := newClearer(bus, send, fakeDevices{"tokA"})
	sub := bus.Subscribe(16)
	defer sub.Close()

	c.handle(statusChange(t, "wN:p9", "idle")) // never armed
	c.handle(statusChange(t, "wN:p2", "blocked"))
	c.handle(blockedPush(t, "wN:p2")) // arm, but no resolution yet

	if send.count() != 0 {
		t.Errorf("dismiss sends = %d, want 0 (nothing resolved)", send.count())
	}
	assertNoCleared(t, sub)
}

// TestDoneStatusPushDoesNotArm: only "blocked" pushes arm; a "done" push must not.
func TestDoneStatusPushDoesNotArm(t *testing.T) {
	bus := events.New()
	send := &fakeSender{}
	c := newClearer(bus, send, fakeDevices{"tokA"})
	sub := bus.Subscribe(16)
	defer sub.Close()

	c.handle(events.Envelope{Source: events.SourceGothalo, Type: events.TypePushSent,
		Payload: raw(t, map[string]any{"agent": "wN:p2", "status": "done"})})
	c.handle(statusChange(t, "wN:p2", "idle"))

	if send.count() != 0 {
		t.Errorf("dismiss sends = %d, want 0 (a done push does not arm)", send.count())
	}
	assertNoCleared(t, sub)
}

// TestRunEndToEnd drives the full wiring: Run subscribes to a real bus, and
// events are delivered via bus.Publish (not handle() directly). A blocked push
// then a resolving status change must produce a dismiss send + a
// notification_cleared delta on the same bus.
func TestRunEndToEnd(t *testing.T) {
	bus := events.New()
	send := &fakeSender{}
	c := newClearer(bus, send, fakeDevices{"tokA"})

	// A watcher of the bus, to observe the notification_cleared the clearer emits.
	watch := bus.Subscribe(32)
	defer watch.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go c.Run(ctx)

	const pane = "wN:p7"
	// Give Run a moment to subscribe before publishing.
	waitFor(t, func() bool { return bus.SubscriberCount() == 2 })

	if _, err := bus.Publish(events.SourceGothalo, events.TypePushSent,
		map[string]any{"agent": pane, "status": "blocked"}); err != nil {
		t.Fatalf("publish push_sent: %v", err)
	}
	waitFor(t, func() bool {
		c.mu.Lock()
		defer c.mu.Unlock()
		_, armed := c.pending[pane]
		return armed
	})

	if _, err := bus.Publish(events.SourceHerdr, events.TypePaneAgentStatusChanged,
		map[string]any{"pane_id": pane, "agent_status": "idle"}); err != nil {
		t.Fatalf("publish status change: %v", err)
	}

	if got := waitCleared(t, watch); got != pane {
		t.Errorf("notification_cleared pane = %q, want %q", got, pane)
	}
	waitFor(t, func() bool { return send.count() == 1 })
	if last := send.last(); last["type"] != "dismiss" || last["agent"] != pane {
		t.Errorf("dismiss data = %v, want type=dismiss agent=%s", last, pane)
	}
}

// waitFor polls cond up to a second.
func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for {
		if cond() {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("condition not met within 1s")
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// TestFCMDisabledNoOp: with no FCM client, an armed pane still resolves cleanly
// (no send, no panic) and still publishes the consistency event.
func TestFCMDisabledNoOp(t *testing.T) {
	bus := events.New()
	c := newClearer(bus, nil, fakeDevices{"tokA"}) // push == nil
	sub := bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p2"
	c.handle(blockedPush(t, pane))
	c.handle(statusChange(t, pane, "idle"))

	if got := waitCleared(t, sub); got != pane {
		t.Errorf("notification_cleared pane = %q, want %q", got, pane)
	}
}
