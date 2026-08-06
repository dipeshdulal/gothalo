package timeline

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/dipeshdulal/gothalo/internal/events"
)

// fakeAgents stands in for Herdr: what an authoritative read reports RIGHT NOW,
// independently of anything the bus has said. The two disagreeing is the whole
// reason [Recorder.reconcile] exists, so the fixture keeps them separate.
type fakeAgents struct {
	mu    sync.Mutex
	panes []PaneState
	err   error
}

// exists registers a pane as live without disturbing the configured states. A
// pane that emits a status transition necessarily exists, and the recorder now
// checks that before recording a first sighting (it is how a replayed ghost is
// told from a genuinely new pane), so the fixture has to model it.
func (f *fakeAgents) exists(pane string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, p := range f.panes {
		if p.Pane == pane {
			return
		}
	}
	f.panes = append(f.panes, PaneState{Pane: pane})
}

func (f *fakeAgents) set(states ...PaneState) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.panes, f.err = states, nil
}

// fail makes every read error, as an unreachable (or not-yet-started) Herdr does.
func (f *fakeAgents) fail(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.err = err
}

func (f *fakeAgents) Agents() ([]PaneState, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return nil, f.err
	}
	return append([]PaneState(nil), f.panes...), nil
}

// fixture wires a Recorder over a memory-only ring and a fake authoritative
// read, both pinned to the same fake clock.
type fixture struct {
	log    *Log
	agents *fakeAgents
	rec    *Recorder
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{log: newLog(base), agents: &fakeAgents{}}
	f.rec = NewRecorder(f.log, events.New(), f.agents)
	f.rec.now = func() time.Time { return base }
	return f
}

// tick moves both clocks forward, so a reconcile that opens a span at "now"
// stamps a time the test can predict.
func (f *fixture) tick(d time.Duration) {
	at := base.Add(d)
	f.rec.now = func() time.Time { return at }
	f.log.now = func() time.Time { return at }
}

// status delivers a normalized agent-status envelope, the shape the ingester
// publishes (see internal/herdr/ingest.go).
func (f *fixture) status(t *testing.T, d time.Duration, pane, agent, status string) {
	t.Helper()
	f.agents.exists(pane)
	f.rec.handle(envelope(t, events.SourceHerdr, events.TypePaneAgentStatusChanged, at(d), map[string]any{
		"pane_id": pane, "workspace_id": "w1", "agent": agent,
		"agent_status": status, "session": "default",
	}))
}

func envelope(t *testing.T, source, typ string, ts int64, payload any) events.Envelope {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	return events.Envelope{Source: source, Type: typ, TS: ts, Payload: b}
}

// only returns the single entry the ring is expected to hold.
func (f *fixture) only(t *testing.T) Entry {
	t.Helper()
	got := f.log.Entries(0, "")
	if len(got) != 1 {
		t.Fatalf("ring holds %d entries, want 1: %+v", len(got), got)
	}
	return got[0]
}

// The first time the bridge sees a pane there is no previous status to measure,
// and prev_ms must be ABSENT rather than zero — zero is a real value (an
// instantaneous flip) and conflating them would show "0s" for every new agent.
func TestFirstSightingHasNoDuration(t *testing.T) {
	f := newFixture(t)
	f.status(t, 0, "w1:p1", "claude", "working")

	e := f.only(t)
	if e.From != "" {
		t.Errorf("from = %q, want empty", e.From)
	}
	if e.To != "working" {
		t.Errorf("to = %q, want working", e.To)
	}
	if e.PrevMS != nil {
		t.Errorf("prev_ms = %d, want absent", *e.PrevMS)
	}
	if e.Agent != "claude" || e.Session != "default" || e.Workspace != "w1" {
		t.Errorf("context not carried: %+v", e)
	}
}

// The duration spent in the status just left is the number the whole feature
// exists for: "blocked for 50m" rather than "blocked".
func TestRecordsDurationOfPreviousStatus(t *testing.T) {
	f := newFixture(t)
	f.status(t, 0, "w1:p1", "claude", "working")
	f.status(t, 50*time.Minute, "w1:p1", "claude", "blocked")

	got := f.log.Entries(0, "")
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
	e := got[0] // newest first
	if e.From != "working" || e.To != "blocked" {
		t.Errorf("transition = %q -> %q, want working -> blocked", e.From, e.To)
	}
	if e.PrevMS == nil {
		t.Fatal("prev_ms absent, want 50m")
	}
	if want := (50 * time.Minute).Milliseconds(); *e.PrevMS != want {
		t.Errorf("prev_ms = %d, want %d", *e.PrevMS, want)
	}
}

// An instantaneous flip is a real zero, and must be reported as one.
func TestZeroDurationIsRecordedNotDropped(t *testing.T) {
	f := newFixture(t)
	f.status(t, 0, "w1:p1", "claude", "working")
	f.status(t, 0, "w1:p1", "claude", "blocked")

	e := f.log.Entries(0, "")[0]
	if e.PrevMS == nil {
		t.Fatal("prev_ms absent, want 0")
	}
	if *e.PrevMS != 0 {
		t.Errorf("prev_ms = %d, want 0", *e.PrevMS)
	}
}

// The ingester dedupes per ingester, so a Herdr reconnect can legitimately
// re-announce a status that already holds. Recording it would show a transition
// that never happened AND reset the duration that made the row worth reading.
func TestRepeatedStatusIsIgnored(t *testing.T) {
	f := newFixture(t)
	f.status(t, 0, "w1:p1", "claude", "blocked")
	f.status(t, 10*time.Minute, "w1:p1", "claude", "blocked")
	f.status(t, 20*time.Minute, "w1:p1", "claude", "blocked")

	if f.log.Len() != 1 {
		t.Fatalf("Len = %d, want 1 — a repeat of the open status was recorded", f.log.Len())
	}
	// The span must still be measured from the FIRST sighting, not the repeat.
	f.status(t, 30*time.Minute, "w1:p1", "claude", "idle")
	e := f.log.Entries(0, "")[0]
	if want := (30 * time.Minute).Milliseconds(); e.PrevMS == nil || *e.PrevMS != want {
		t.Errorf("prev_ms = %v, want %d — the repeat reset the span", e.PrevMS, want)
	}
}

// A status event is not guaranteed to repeat the agent kind, and a row that
// cannot name its agent is unreadable — so the span remembers the context the
// pane was last seen with.
func TestContextFallsBackToTheOpenSpan(t *testing.T) {
	f := newFixture(t)
	f.status(t, 0, "w1:p1", "claude", "working")
	f.rec.handle(envelope(t, events.SourceHerdr, events.TypePaneAgentStatusChanged, at(time.Minute),
		map[string]any{"pane_id": "w1:p1", "agent_status": "blocked"}))

	e := f.log.Entries(0, "")[0]
	if e.Agent != "claude" || e.Session != "default" || e.Workspace != "w1" {
		t.Errorf("context not inherited from the open span: %+v", e)
	}
}

// A closing pane is the most informative transition there is — it says the agent
// stopped rather than went quiet — so the open span is closed with a real
// duration instead of being abandoned mid-flight.
func TestPaneClosedRecordsGone(t *testing.T) {
	for _, typ := range []string{events.TypePaneClosed, events.TypePaneExited} {
		t.Run(typ, func(t *testing.T) {
			f := newFixture(t)
			f.status(t, 0, "w1:p1", "claude", "working")
			f.rec.handle(envelope(t, events.SourceHerdr, typ, at(40*time.Minute),
				map[string]any{"pane_id": "w1:p1"}))

			e := f.log.Entries(0, "")[0]
			if e.From != "working" || e.To != StatusGone {
				t.Errorf("transition = %q -> %q, want working -> %s", e.From, e.To, StatusGone)
			}
			if want := (40 * time.Minute).Milliseconds(); e.PrevMS == nil || *e.PrevMS != want {
				t.Errorf("prev_ms = %v, want %d", e.PrevMS, want)
			}
			if e.Agent != "claude" {
				t.Errorf("agent = %q, want claude — a close event carries only a pane id", e.Agent)
			}
		})
	}
}

// A plain shell closing is not agent activity; recording every one would bury
// the rows that matter.
func TestPaneClosedForUnknownPaneIsIgnored(t *testing.T) {
	f := newFixture(t)
	f.rec.handle(envelope(t, events.SourceHerdr, events.TypePaneClosed, at(0),
		map[string]any{"pane_id": "w1:p9"}))

	if f.log.Len() != 0 {
		t.Errorf("Len = %d, want 0", f.log.Len())
	}
}

// Both sources of a close are accepted (herdr's own, and gothalo's POST
// /pane/close), and the two arriving for the same pane must record exactly one
// `gone`.
func TestDoubleCloseRecordsOnce(t *testing.T) {
	f := newFixture(t)
	f.status(t, 0, "w1:p1", "claude", "working")
	f.rec.handle(envelope(t, events.SourceHerdr, events.TypePaneClosed, at(time.Minute),
		map[string]any{"pane_id": "w1:p1"}))
	f.rec.handle(envelope(t, events.SourceGothalo, events.TypeGothaloPaneClosed, at(time.Minute),
		map[string]any{"pane_id": "w1:p1"}))

	if got := len(f.log.Entries(0, "w1:p1")); got != 2 {
		t.Errorf("entries = %d, want 2 (one sighting + one gone)", got)
	}
}

// THE restart case. A span that was already running when the bridge stopped has
// a start time that lived only in memory — but the entry that opened it is on
// disk, so the span resumes with its real start and an agent blocked since
// before the restart keeps its number.
func TestReconcileResumesSpanAcrossRestart(t *testing.T) {
	f := newFixture(t)
	// A previous process recorded the pane entering `blocked` an hour ago.
	f.log.Append(Entry{TS: at(-time.Hour), Pane: "w1:p1", Agent: "claude", To: "blocked"})

	f.agents.set(PaneState{Pane: "w1:p1", Agent: "claude", Session: "default",
		Workspace: "w1", Status: "blocked"})
	f.rec.reconcile("startup")

	// Nothing is written by the rebuild itself.
	if f.log.Len() != 1 {
		t.Fatalf("reconcile wrote %d extra entries, want 0", f.log.Len()-1)
	}

	// The next real transition measures from the ORIGINAL block, not from boot.
	f.status(t, 0, "w1:p1", "claude", "idle")
	e := f.log.Entries(0, "")[0]
	if e.From != "blocked" {
		t.Errorf("from = %q, want blocked", e.From)
	}
	if want := time.Hour.Milliseconds(); e.PrevMS == nil || *e.PrevMS != want {
		t.Errorf("prev_ms = %v, want %d (the span did not survive the restart)", e.PrevMS, want)
	}
}

// If the pane moved while the bridge was down, the persisted entry describes a
// status it has already left — so the span cannot be resumed and its first
// transition must carry NO duration rather than one measured from bridge
// startup.
func TestReconcileOpensUnknownSpanWhenPaneMovedWhileDown(t *testing.T) {
	f := newFixture(t)
	f.log.Append(Entry{TS: at(-time.Hour), Pane: "w1:p1", Agent: "claude", To: "working"})

	f.agents.set(PaneState{Pane: "w1:p1", Agent: "claude", Status: "blocked"})
	f.rec.reconcile("startup")
	if f.log.Len() != 1 {
		t.Fatalf("reconcile fabricated %d entries, want 0", f.log.Len()-1)
	}

	f.tick(30 * time.Minute)
	f.status(t, 30*time.Minute, "w1:p1", "claude", "idle")
	e := f.log.Entries(0, "")[0]
	if e.From != "blocked" {
		t.Errorf("from = %q, want blocked — the span should name what Herdr reported", e.From)
	}
	if e.PrevMS != nil {
		t.Errorf("prev_ms = %d, want absent — the span's start was never known", *e.PrevMS)
	}
}

// A span we are already tracking is better information than any read can supply:
// reconcile must not reset its start, or every Herdr reconnect would silently
// truncate the duration of every open span.
func TestReconcileLeavesAMatchingSpanAlone(t *testing.T) {
	f := newFixture(t)
	f.status(t, 0, "w1:p1", "claude", "blocked")

	f.tick(20 * time.Minute)
	f.agents.set(PaneState{Pane: "w1:p1", Agent: "claude", Status: "blocked"})
	f.rec.reconcile("herdr connected")

	f.status(t, 20*time.Minute, "w1:p1", "claude", "idle")
	e := f.log.Entries(0, "")[0]
	if want := (20 * time.Minute).Milliseconds(); e.PrevMS == nil || *e.PrevMS != want {
		t.Errorf("prev_ms = %v, want %d — reconcile reset a span it should not have touched", e.PrevMS, want)
	}
}

// The ingester re-seeds its own status baseline on reconnect, so a pane that
// changed status while the socket was down produces no bus event at all. Left
// alone the span would name a status the agent has left, and the next real
// transition would report that stale status as its `from` with a duration
// covering both spans.
func TestReconcileCorrectsSpanAfterAMissedTransition(t *testing.T) {
	f := newFixture(t)
	f.status(t, 0, "w1:p1", "claude", "working")

	// Herdr was down; it comes back with the pane blocked and no event fired.
	f.tick(10 * time.Minute)
	f.agents.set(PaneState{Pane: "w1:p1", Agent: "claude", Status: "blocked"})
	f.rec.reconcile("herdr connected")
	if f.log.Len() != 1 {
		t.Fatalf("reconcile fabricated %d entries, want 0", f.log.Len()-1)
	}

	f.status(t, 15*time.Minute, "w1:p1", "claude", "idle")
	e := f.log.Entries(0, "")[0]
	if e.From != "blocked" {
		t.Errorf("from = %q, want blocked — the stale span was not corrected", e.From)
	}
	if e.PrevMS != nil {
		t.Errorf("prev_ms = %d, want absent — we never saw when the pane blocked", *e.PrevMS)
	}
}

// An unreadable Herdr must leave the recorder exactly as it was: a failed read
// is not evidence that anything changed.
func TestReconcileToleratesAnUnreadableHerdr(t *testing.T) {
	f := newFixture(t)
	f.status(t, 0, "w1:p1", "claude", "blocked")

	f.agents.fail(errors.New("herdr socket unavailable"))
	f.rec.reconcile("startup")

	f.status(t, 5*time.Minute, "w1:p1", "claude", "idle")
	e := f.log.Entries(0, "")[0]
	if want := (5 * time.Minute).Milliseconds(); e.PrevMS == nil || *e.PrevMS != want {
		t.Errorf("prev_ms = %v, want %d — a failed read disturbed the open span", e.PrevMS, want)
	}
}

// End to end over a real bus: `serve` starts this recorder and the Herdr session
// manager in the same breath, so the startup read usually finds no sessions at
// all. gothalo.herdr_connected is the event that says "now there is one", and
// without acting on it every duration would be lost on every restart.
func TestRunReconcilesWhenHerdrConnects(t *testing.T) {
	dir := t.TempDir()
	l := Open(dir + "/timeline.json")
	l.Append(Entry{TS: time.Now().Add(-time.Hour).UnixMilli(), Pane: "w1:p1", To: "blocked"})

	agents := &fakeAgents{}
	agents.fail(errors.New("no herdr sessions yet")) // as at process start

	bus := events.New()
	rec := NewRecorder(l, bus, agents)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go rec.Run(ctx)

	// Herdr comes up and the ingester announces it.
	agents.set(PaneState{Pane: "w1:p1", Agent: "claude", Status: "blocked"})
	waitFor(t, func() bool { return subscribed(bus) }, "recorder subscribed")
	if _, err := bus.Publish(events.SourceGothalo, events.TypeHerdrConnected,
		map[string]any{"socket": "/tmp/herdr.sock", "session": "default"}); err != nil {
		t.Fatalf("publish herdr_connected: %v", err)
	}

	// Now a real transition: its duration must span back to the persisted entry,
	// which only happens if the reconnect rebuilt the span.
	waitFor(t, func() bool { return rec.tracking("w1:p1") }, "span rebuilt")
	if _, err := bus.Publish(events.SourceHerdr, events.TypePaneAgentStatusChanged,
		map[string]any{"pane_id": "w1:p1", "agent": "claude", "agent_status": "idle"}); err != nil {
		t.Fatalf("publish status change: %v", err)
	}
	waitFor(t, func() bool { return l.Len() == 2 }, "transition recorded")

	e := l.Entries(0, "")[0]
	if e.From != "blocked" || e.To != "idle" {
		t.Fatalf("transition = %q -> %q, want blocked -> idle", e.From, e.To)
	}
	if e.PrevMS == nil {
		t.Fatal("prev_ms absent — the span was never resumed from the persisted entry")
	}
	if *e.PrevMS < time.Hour.Milliseconds() {
		t.Errorf("prev_ms = %d, want at least an hour", *e.PrevMS)
	}

	// And the ring is flushed on the way out, so a clean shutdown loses nothing.
	cancel()
	waitFor(t, func() bool {
		reopened := Open(dir + "/timeline.json")
		return reopened.Len() == 2
	}, "flushed on shutdown")
}

// tracking reports whether the recorder holds an open span for a pane. Test-only
// window onto the one piece of state that is otherwise invisible.
func (r *Recorder) tracking(pane string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, ok := r.spans[pane]
	return ok
}

// subscribed reports whether the recorder's Run loop has got as far as
// subscribing — publishing before it has would deliver to nobody.
func subscribed(b *events.Bus) bool { return b.SubscriberCount() > 0 }

func waitFor(t *testing.T, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// TestReplayedTransitionForDeadPaneIsDropped is the regression test for the bug
// that made this feature actively misleading in practice.
//
// Herdr re-delivers recent events to a new subscriber and its subscription_event
// carries no timestamp, so the bus stamps the replay with time.Now(). Recording
// it dates an hour-old transition as happening this second — and it repeats on
// every restart, so the bounded ring fills with re-dated ghosts that evict the
// real history. Observed live: 33 entries became 61 after one restart, the extra
// 28 all for panes closed half an hour earlier.
//
// A pane that no longer exists cannot be transitioning now, and that is the only
// thing separating a ghost from a genuinely new pane.
func TestReplayedTransitionForDeadPaneIsDropped(t *testing.T) {
	f := newFixture(t)
	// A pane herdr replays but which is gone: never registered as existing.
	f.rec.handle(envelope(t, events.SourceHerdr, events.TypePaneAgentStatusChanged, at(0), map[string]any{
		"pane_id": "w1:pDEAD", "workspace_id": "w1", "agent": "claude",
		"agent_status": "idle", "session": "default",
	}))
	if got := f.log.Entries(0, ""); len(got) != 0 {
		t.Fatalf("recorded %d entries for a pane that no longer exists: %+v", len(got), got)
	}
}

// TestNewPaneIsStillRecorded: the guard must not swallow real work. A brand-new
// pane is unknown to the recorder for exactly the same reason a dead one is, so
// the check has to re-read rather than trust a cached set.
func TestNewPaneIsStillRecorded(t *testing.T) {
	f := newFixture(t)
	f.status(t, 0, "w1:p1", "claude", "working") // exists → recorded
	e := f.only(t)
	if e.To != "working" || e.Pane != "w1:p1" {
		t.Fatalf("first sighting of a live pane not recorded correctly: %+v", e)
	}
}

// TestUnreadableStateRecordsAnyway: if existence cannot be determined, a real
// transition must not be silently dropped. A wrong entry is visible and
// correctable; a missing one is neither.
func TestUnreadableStateRecordsAnyway(t *testing.T) {
	f := newFixture(t)
	f.agents.fail(errors.New("herdr socket unavailable"))
	f.rec.handle(envelope(t, events.SourceHerdr, events.TypePaneAgentStatusChanged, at(0), map[string]any{
		"pane_id": "w1:p9", "workspace_id": "w1", "agent": "claude",
		"agent_status": "working", "session": "default",
	}))
	if got := f.log.Entries(0, ""); len(got) != 1 {
		t.Fatalf("len = %d, want 1 (an unreadable state must not drop a transition)", len(got))
	}
}

// TestDeadPaneDropDoesNotBlockItsLaterReuse guards the cache: a miss must not be
// remembered so long that a pane appearing moments later is ignored too.
func TestDeadPaneDropDoesNotBlockItsLaterReuse(t *testing.T) {
	f := newFixture(t)
	f.rec.handle(envelope(t, events.SourceHerdr, events.TypePaneAgentStatusChanged, at(0), map[string]any{
		"pane_id": "w1:p7", "workspace_id": "w1", "agent": "claude",
		"agent_status": "idle", "session": "default",
	}))
	if got := f.log.Entries(0, ""); len(got) != 0 {
		t.Fatalf("ghost recorded: %+v", got)
	}
	// The pane now exists, and the cached miss has aged out.
	f.tick(liveTTL + time.Second)
	f.status(t, liveTTL+time.Second, "w1:p7", "claude", "working")
	if got := f.log.Entries(0, ""); len(got) != 1 {
		t.Fatalf("len = %d, want 1 — a pane that appears after a miss must record", len(got))
	}
}

// TestSeenFlipIsNotATransition covers the bug that quietly destroyed the number
// this whole feature exists to report.
//
// Herdr's `done` and `idle` are one state — a resting agent — distinguished only
// by whether its tab has been seen. Treating the flip as a transition re-opened
// the span, so glancing at a tab reset the clock: an agent resting since 11:40
// reported "working after 0.1s idle" at 11:46.
func TestSeenFlipIsNotATransition(t *testing.T) {
	f := newFixture(t)
	f.status(t, 0, "w1:p1", "claude", "done")             // resting since t=0
	f.status(t, 6*time.Minute, "w1:p1", "claude", "idle") // someone looks at the tab
	f.status(t, 6*time.Minute, "w1:p1", "claude", "working")

	got := f.log.Entries(0, "")
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2 — the seen flip must not be recorded: %+v", len(got), got)
	}
	e := got[0] // newest first
	if e.To != "working" {
		t.Fatalf("newest = %q, want working", e.To)
	}
	if e.PrevMS == nil {
		t.Fatal("prev_ms absent")
	}
	if want := (6 * time.Minute).Milliseconds(); *e.PrevMS != want {
		t.Errorf("prev_ms = %d, want %d — the rest period must survive the glance", *e.PrevMS, want)
	}
}

// TestRestingFlipBothDirections: idle->done is the same non-event as done->idle
// (work finishes unseen while the agent is already resting).
func TestRestingFlipBothDirections(t *testing.T) {
	f := newFixture(t)
	f.status(t, 0, "w1:p1", "claude", "idle")
	f.status(t, time.Minute, "w1:p1", "claude", "done")
	if got := f.log.Entries(0, ""); len(got) != 1 {
		t.Fatalf("len = %d, want 1 — idle->done is not a transition: %+v", len(got), got)
	}
}

// TestRealTransitionsStillRecorded guards against over-filtering: leaving and
// entering the resting state are exactly what a reader wants to see.
func TestRealTransitionsStillRecorded(t *testing.T) {
	f := newFixture(t)
	f.status(t, 0, "w1:p1", "claude", "idle")
	f.status(t, time.Minute, "w1:p1", "claude", "working")
	f.status(t, 2*time.Minute, "w1:p1", "claude", "blocked")
	f.status(t, 3*time.Minute, "w1:p1", "claude", "done")

	got := f.log.Entries(0, "")
	if len(got) != 4 {
		t.Fatalf("len = %d, want 4 real transitions: %+v", len(got), got)
	}
	if got[0].From != "blocked" || got[0].To != "done" {
		t.Errorf("newest = %q -> %q, want blocked -> done", got[0].From, got[0].To)
	}
}
