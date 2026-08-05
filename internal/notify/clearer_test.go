package notify

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/dipeshdulal/gothalo/internal/events"
	"github.com/dipeshdulal/gothalo/internal/push"
)

// testServerID is the bridge identity every dismiss in these tests is scoped to.
const testServerID = "srv1"

// fakeSender records every dismiss send so a test can assert the exact payload
// and count.
type fakeSender struct {
	mu    sync.Mutex
	sends []map[string]string
}

func (f *fakeSender) SendMessage(m push.Message) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	cp := map[string]string{
		"__token": m.Token, "__title": m.Title, "__body": m.Body,
		"__kind": string(m.Kind), "__tag": m.Tag,
	}
	for k, v := range m.Data {
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

// fakeAgents stands in for Herdr: what an authoritative read would return right
// now. Tests set it to whatever the agent's real state is, independently of what
// the bus is saying — which is the whole point, since the two can disagree.
type fakeAgents struct {
	mu     sync.Mutex
	status map[string]string
	seq    map[string]int
	err    error
}

func newFakeAgents() *fakeAgents {
	return &fakeAgents{status: map[string]string{}, seq: map[string]int{}}
}

func (f *fakeAgents) set(pane, status string, seq int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.status[pane] = status
	f.seq[pane] = seq
}

// fail makes every read return an error, as an unreachable Herdr would.
func (f *fakeAgents) fail(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.err = err
}

func (f *fakeAgents) AgentState(pane string) (string, int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return "", 0, f.err
	}
	st, ok := f.status[pane]
	if !ok {
		return "", 0, errors.New("pane not found")
	}
	return st, f.seq[pane], nil
}

// fixture wires a Clearer over fakes and models the fact that Herdr's state and
// the bus nudge about it are two separate things.
type fixture struct {
	bus    *events.Bus
	send   *fakeSender
	agents *fakeAgents
	c      *Clearer
}

func newFixture(tokens ...string) *fixture {
	f := &fixture{bus: events.New(), send: &fakeSender{}, agents: newFakeAgents()}
	f.c = newClearer(f.bus, f.send, fakeDevices(tokens), testServerID, f.agents)
	return f
}

// moveTo is a real transition: Herdr's state changes AND a bus event announces
// it. Use this for anything that actually happened.
func (f *fixture) moveTo(t *testing.T, pane, status string, seq int) {
	t.Helper()
	f.agents.set(pane, status, seq)
	f.c.handle(statusChange(t, pane, status))
}

// nudge delivers a bus event WITHOUT changing Herdr's state — a stale or coarse
// event, which is exactly what a pane created after connect produces.
func (f *fixture) nudge(t *testing.T, pane, claimedStatus string) {
	t.Helper()
	f.c.handle(statusChange(t, pane, claimedStatus))
}

func raw(t *testing.T, v any) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}

func pushSent(t *testing.T, pane, status string, seq int) events.Envelope {
	return events.Envelope{Source: events.SourceGothalo, Type: events.TypePushSent,
		Payload: raw(t, map[string]any{"agent": pane, "status": status, "seq": seq})}
}

func blockedPush(t *testing.T, pane string, seq int) events.Envelope {
	return pushSent(t, pane, "blocked", seq)
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

// TestStaleBusStatusIgnored is the regression test for the bug that made every
// blocked notification self-destruct.
//
// The bus said "idle" while the agent was really blocked. That is not exotic: a
// pane created after the bridge connected has no targeted Herdr subscription, so
// its status is only ever scavenged out of structural events and lags — measured
// at 57 seconds of silence across an idle→working→blocked run. The old code
// compared that stale value against the push's announcement and concluded the
// push had been overtaken, dismissing a notification for an agent that was
// waiting on the user right then.
func TestStaleBusStatusIgnored(t *testing.T) {
	f := newFixture("tokA")
	sub := f.bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p25"
	// Herdr's truth: blocked at seq 302. The bus, however, still believes idle.
	f.agents.set(pane, "blocked", 302)
	f.nudge(t, pane, "idle")

	f.c.handle(blockedPush(t, pane, 302))

	if got := f.send.count(); got != 0 {
		t.Fatalf("dismiss sends = %d, want 0 — the agent is blocked right now", got)
	}
	assertNoCleared(t, sub)

	f.c.mu.Lock()
	a, armed := f.c.pending[pane]
	f.c.mu.Unlock()
	if !armed {
		t.Fatal("pane not armed; the live notification has nothing to clear it later")
	}
	if a.seq != 302 {
		t.Errorf("armed seq = %d, want 302", a.seq)
	}
}

// TestArmThenDismiss: a blocked push arms the pane; the resolving transition
// dismisses it (data-only "dismiss" to every device) and publishes
// notification_cleared. A repeat of the same resolution does NOT dismiss again.
func TestArmThenDismiss(t *testing.T) {
	f := newFixture("tokA", "tokB")
	sub := f.bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p2"
	f.agents.set(pane, "blocked", 10)
	f.c.handle(blockedPush(t, pane, 10))
	f.moveTo(t, pane, "idle", 11)

	if got := f.send.count(); got != 2 {
		t.Fatalf("dismiss sends = %d, want 2 (one per device)", got)
	}
	last := f.send.last()
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
	f.moveTo(t, pane, "working", 12)
	if got := f.send.count(); got != 2 {
		t.Errorf("after second resolution sends = %d, want still 2 (no double-dismiss)", got)
	}
	assertNoCleared(t, sub)
}

// TestReArmOnNewBlock: after a dismiss, a fresh blocked push re-arms the pane so
// the next resolution dismisses again.
func TestReArmOnNewBlock(t *testing.T) {
	f := newFixture("tokA")
	sub := f.bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p2"
	f.agents.set(pane, "blocked", 10)
	f.c.handle(blockedPush(t, pane, 10))
	f.moveTo(t, pane, "working", 11)
	if f.send.count() != 1 {
		t.Fatalf("first dismiss sends = %d, want 1", f.send.count())
	}
	_ = waitCleared(t, sub)

	// Re-arm on a new block, then close the pane -> dismiss again.
	f.agents.set(pane, "blocked", 12)
	f.c.handle(blockedPush(t, pane, 12))
	f.c.handle(paneExited(t, pane))
	if f.send.count() != 2 {
		t.Fatalf("after re-arm dismiss sends = %d, want 2", f.send.count())
	}
	if got := waitCleared(t, sub); got != pane {
		t.Errorf("second notification_cleared pane = %q, want %q", got, pane)
	}
}

// TestUnarmedResolutionIgnored: a resolution for a pane that never had a blocked
// push triggers nothing — and must not cost a Herdr read either.
func TestUnarmedResolutionIgnored(t *testing.T) {
	f := newFixture("tokA")
	sub := f.bus.Subscribe(16)
	defer sub.Close()

	f.moveTo(t, "wN:p9", "idle", 1) // never armed
	f.agents.set("wN:p2", "blocked", 2)
	f.nudge(t, "wN:p2", "blocked")
	f.c.handle(blockedPush(t, "wN:p2", 2)) // arm, but no resolution yet

	if f.send.count() != 0 {
		t.Errorf("dismiss sends = %d, want 0 (nothing resolved)", f.send.count())
	}
	assertNoCleared(t, sub)
}

// TestDonePushClearsOnlyWhenAgentMovesOn: a "done" push arms like a blocked one,
// but a completion notice stays true for as long as the agent sits in done — it
// is only stale once the agent starts working again.
//
// Worth knowing why that transition can happen with the agent doing nothing:
// Herdr projects `done` as AgentState::Idle + seen == false, so merely focusing
// the pane on the desktop flips it to `idle`. See docs/CONTRACT-notifications.md.
func TestDonePushClearsOnlyWhenAgentMovesOn(t *testing.T) {
	f := newFixture("tokA")
	sub := f.bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p2"
	f.agents.set(pane, "done", 20)
	f.c.handle(pushSent(t, pane, "done", 20))

	// The transition that raised the notice must not clear it.
	f.moveTo(t, pane, "done", 20)
	if f.send.count() != 0 {
		t.Fatalf("dismiss sends = %d, want 0 while the agent is still done", f.send.count())
	}
	assertNoCleared(t, sub)

	f.moveTo(t, pane, "working", 21)
	if f.send.count() != 1 {
		t.Fatalf("dismiss sends = %d, want 1 once the agent moved on", f.send.count())
	}
	if got := waitCleared(t, sub); got != pane {
		t.Errorf("notification_cleared pane = %q, want %q", got, pane)
	}
}

// TestBlockedNotClearedWhileStillBlocked: Herdr re-emits agent_status_changed on
// presentation changes too (a terminal title update while blocked), so the same
// status arrives repeatedly. That must never clear a live block.
func TestBlockedNotClearedWhileStillBlocked(t *testing.T) {
	f := newFixture("tokA")
	sub := f.bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p2"
	f.agents.set(pane, "blocked", 30)
	f.c.handle(blockedPush(t, pane, 30))
	f.moveTo(t, pane, "blocked", 30)
	f.moveTo(t, pane, "blocked", 30)

	if f.send.count() != 0 {
		t.Errorf("dismiss sends = %d, want 0 (still blocked)", f.send.count())
	}
	assertNoCleared(t, sub)
}

// TestResolutionBeforePush is the regression test for the race that left
// notifications stuck in the tray forever.
//
// Composing a push costs several Herdr reads, so the agent can be answered from
// the desktop before the fan-out finishes. The resolving transition then arrives
// while the pane is not yet armed and is dropped; arming afterwards would strand
// a notification nothing will ever clear.
func TestResolutionBeforePush(t *testing.T) {
	f := newFixture("tokA")
	sub := f.bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p1W"
	f.moveTo(t, pane, "blocked", 40)
	f.moveTo(t, pane, "working", 41) // answered at the desk, before the push landed
	f.c.handle(blockedPush(t, pane, 40))

	if f.send.count() != 1 {
		t.Fatalf("dismiss sends = %d, want 1 (the push was overtaken in flight)", f.send.count())
	}
	if got := waitCleared(t, sub); got != pane {
		t.Errorf("notification_cleared pane = %q, want %q", got, pane)
	}

	f.c.mu.Lock()
	_, stillArmed := f.c.pending[pane]
	f.c.mu.Unlock()
	if stillArmed {
		t.Error("pane left armed after an overtaken push; it would never clear")
	}
}

// TestReBlockedBeforeArmStaysArmed: blocked -> working -> blocked, all before the
// first push arms. The notification still says "needs you", which is true, and a
// newer push shares its tag and will replace the contents. Dismissing here would
// race that push and could cancel the fresh notification.
func TestReBlockedBeforeArmStaysArmed(t *testing.T) {
	f := newFixture("tokA")
	sub := f.bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p3"
	f.agents.set(pane, "blocked", 52) // re-entered blocked at a NEWER seq
	f.c.handle(blockedPush(t, pane, 50))

	if f.send.count() != 0 {
		t.Fatalf("dismiss sends = %d, want 0 — the agent still needs the user", f.send.count())
	}
	assertNoCleared(t, sub)

	f.c.mu.Lock()
	a := f.c.pending[pane]
	f.c.mu.Unlock()
	if a.seq != 52 {
		t.Errorf("armed seq = %d, want 52 (the freshly observed one, not the announced 50)", a.seq)
	}
}

// TestReadFailureLeavesNotificationAlone: when Herdr can't be reached we cannot
// know whether the notification is still true. Erring towards keeping it is
// deliberate — a lingering alert is a nuisance, a vanished one is the failure
// this subsystem exists to prevent.
func TestReadFailureLeavesNotificationAlone(t *testing.T) {
	f := newFixture("tokA")
	sub := f.bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p2"
	f.agents.set(pane, "blocked", 60)
	f.c.handle(blockedPush(t, pane, 60))

	f.agents.fail(errors.New("herdr unreachable"))
	f.nudge(t, pane, "idle")

	if f.send.count() != 0 {
		t.Errorf("dismiss sends = %d, want 0 (state unknown, so leave it alone)", f.send.count())
	}
	assertNoCleared(t, sub)

	f.c.mu.Lock()
	_, armed := f.c.pending[pane]
	f.c.mu.Unlock()
	if !armed {
		t.Error("pane disarmed on an unreadable state; it could never be cleared afterwards")
	}
}

// TestPaneGoneDismissesWithoutRead: a closed pane is unambiguous — there is no
// state to read and nothing the notification could still be true about.
func TestPaneGoneDismissesWithoutRead(t *testing.T) {
	f := newFixture("tokA")
	sub := f.bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p2"
	f.agents.set(pane, "blocked", 70)
	f.c.handle(blockedPush(t, pane, 70))

	f.agents.fail(errors.New("pane not found")) // it's gone
	f.c.handle(paneExited(t, pane))

	if f.send.count() != 1 {
		t.Fatalf("dismiss sends = %d, want 1 (the pane is gone)", f.send.count())
	}
	if got := waitCleared(t, sub); got != pane {
		t.Errorf("notification_cleared pane = %q, want %q", got, pane)
	}
}

// TestDismissPayload asserts the shape the app depends on: a silent, data-only
// message tagged with "<server>/<pane>" and scoped to this bridge.
func TestDismissPayload(t *testing.T) {
	f := newFixture("tokA")
	sub := f.bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p2"
	f.agents.set(pane, "blocked", 80)
	f.c.handle(blockedPush(t, pane, 80))
	f.moveTo(t, pane, "idle", 81)
	_ = waitCleared(t, sub)

	last := f.send.last()
	if last["__kind"] != "data" {
		t.Errorf("dismiss kind = %q, want data-only (it must never draw a notification)", last["__kind"])
	}
	if want := testServerID + "/" + pane; last["__tag"] != want {
		t.Errorf("dismiss tag = %q, want %q", last["__tag"], want)
	}
	if last["server_id"] != testServerID {
		t.Errorf("dismiss server_id = %q, want %q", last["server_id"], testServerID)
	}
}

// TestRunEndToEnd drives the full wiring: Run subscribes to a real bus, and
// events are delivered via bus.Publish (not handle() directly).
func TestRunEndToEnd(t *testing.T) {
	f := newFixture("tokA")

	// A watcher of the bus, to observe the notification_cleared the clearer emits.
	watch := f.bus.Subscribe(32)
	defer watch.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go f.c.Run(ctx)

	const pane = "wN:p7"
	// Give Run a moment to subscribe before publishing.
	waitFor(t, func() bool { return f.bus.SubscriberCount() == 2 })

	f.agents.set(pane, "blocked", 90)
	if _, err := f.bus.Publish(events.SourceGothalo, events.TypePushSent,
		map[string]any{"agent": pane, "status": "blocked", "seq": 90}); err != nil {
		t.Fatalf("publish push_sent: %v", err)
	}
	waitFor(t, func() bool {
		f.c.mu.Lock()
		defer f.c.mu.Unlock()
		_, armed := f.c.pending[pane]
		return armed
	})

	f.agents.set(pane, "idle", 91)
	if _, err := f.bus.Publish(events.SourceHerdr, events.TypePaneAgentStatusChanged,
		map[string]any{"pane_id": pane, "agent_status": "idle"}); err != nil {
		t.Fatalf("publish status change: %v", err)
	}

	if got := waitCleared(t, watch); got != pane {
		t.Errorf("notification_cleared pane = %q, want %q", got, pane)
	}
	waitFor(t, func() bool { return f.send.count() == 1 })
	if last := f.send.last(); last["type"] != "dismiss" || last["agent"] != pane {
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
	agents := newFakeAgents()
	c := newClearer(bus, nil, fakeDevices{"tokA"}, testServerID, agents) // push == nil
	sub := bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p2"
	agents.set(pane, "blocked", 100)
	c.handle(blockedPush(t, pane, 100))
	agents.set(pane, "idle", 101)
	c.handle(statusChange(t, pane, "idle"))

	if got := waitCleared(t, sub); got != pane {
		t.Errorf("notification_cleared pane = %q, want %q", got, pane)
	}
}

// TestSweepDismissesWithoutAnyBusEvent is the other half of the fix.
//
// A pane created after the bridge connected has no targeted Herdr subscription,
// so its resolution produces NO bus event whatsoever — verified on-device: the
// agent went blocked -> idle and the tray notification stayed put because
// nothing ever nudged the clearer. Correctness therefore cannot depend on the
// bus; the periodic sweep is what actually guarantees the dismiss.
func TestSweepDismissesWithoutAnyBusEvent(t *testing.T) {
	f := newFixture("tokA")
	sub := f.bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p27"
	f.agents.set(pane, "blocked", 386)
	f.c.handle(blockedPush(t, pane, 386))

	// The agent is answered at the desk. No bus event is delivered at all.
	f.agents.set(pane, "idle", 387)

	f.c.sweep()

	if f.send.count() != 1 {
		t.Fatalf("dismiss sends = %d, want 1 — the sweep must clear it unaided", f.send.count())
	}
	if got := waitCleared(t, sub); got != pane {
		t.Errorf("notification_cleared pane = %q, want %q", got, pane)
	}
}

// TestSweepLeavesLiveNotifications: a sweep must not clear a notification that is
// still true, however many times it runs.
func TestSweepLeavesLiveNotifications(t *testing.T) {
	f := newFixture("tokA")
	sub := f.bus.Subscribe(16)
	defer sub.Close()

	const pane = "wN:p2"
	f.agents.set(pane, "blocked", 400)
	f.c.handle(blockedPush(t, pane, 400))

	f.c.sweep()
	f.c.sweep()
	f.c.sweep()

	if f.send.count() != 0 {
		t.Errorf("dismiss sends = %d, want 0 (still blocked)", f.send.count())
	}
	assertNoCleared(t, sub)
}
