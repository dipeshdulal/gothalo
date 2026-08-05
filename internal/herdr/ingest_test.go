package herdr

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/dipeshdulal/gothalo/internal/events"
)

// collect drains up to want envelopes from a subscription (or fails on timeout).
func collect(t *testing.T, s *events.Sub, want int) []events.Envelope {
	t.Helper()
	var got []events.Envelope
	deadline := time.After(time.Second)
	for len(got) < want {
		select {
		case e, ok := <-s.C():
			if !ok {
				t.Fatalf("sub closed after %d/%d", len(got), want)
			}
			got = append(got, e)
		case <-deadline:
			t.Fatalf("timed out after %d/%d envelopes", len(got), want)
		}
	}
	// Give a beat to ensure no extra unexpected envelope is pending.
	select {
	case e := <-s.C():
		t.Fatalf("unexpected extra envelope: %s/%s", e.Source, e.Type)
	case <-time.After(50 * time.Millisecond):
	}
	return got
}

func msg(event, data string) SocketMessage {
	return SocketMessage{Event: event, Data: json.RawMessage(data)}
}

// Real payloads captured from herdr 0.7.5 (protocol 17) via events.subscribe.
const (
	samplerPaneFocused       = `{"pane_id":"wN:pC","type":"pane_focused","workspace_id":"wN"}`
	samplerPaneUpdatedAgent  = `{"pane":{"agent":"claude","agent_status":"idle","pane_id":"wN:pB","workspace_id":"wN","tab_id":"wN:t1","revision":6},"type":"pane_updated"}`
	samplerDottedAgentStatus = `{"agent":"claude","agent_status":"working","pane_id":"wN:pB","workspace_id":"wN"}`
	samplerPaneAgentDetected = `{"agent":"claude","final_status":"idle","pane_id":"wN:pE","released":true,"type":"pane_agent_detected","workspace_id":"wN"}`
)

func TestForwardsGlobalEventSessionTagged(t *testing.T) {
	bus := events.New()
	sub := bus.Subscribe(16)
	defer sub.Close()
	ing := NewIngester(New(), bus)

	ing.handle(msg("pane_focused", samplerPaneFocused))

	e := collect(t, sub, 1)[0]
	if e.Source != events.SourceHerdr || e.Type != events.TypePaneFocused {
		t.Fatalf("got %s/%s, want herdr/pane_focused", e.Source, e.Type)
	}
	// Herdr's data object is forwarded with the session label stamped on; the
	// default session's ids stay unqualified.
	var p struct {
		PaneID  string `json:"pane_id"`
		Session string `json:"session"`
	}
	if err := json.Unmarshal(e.Payload, &p); err != nil {
		t.Fatal(err)
	}
	if p.PaneID != "wN:pC" || p.Session != "default" {
		t.Errorf("payload = %s, want unqualified pane_id + session=default", e.Payload)
	}
}

func TestForwardsGlobalEventQualifiedForNamedSession(t *testing.T) {
	bus := events.New()
	sub := bus.Subscribe(16)
	defer sub.Close()
	ing := NewIngester(NewForSession("acme"), bus)

	ing.handle(msg("pane_focused", samplerPaneFocused))

	e := collect(t, sub, 1)[0]
	var p struct {
		PaneID  string `json:"pane_id"`
		Session string `json:"session"`
	}
	if err := json.Unmarshal(e.Payload, &p); err != nil {
		t.Fatal(err)
	}
	if p.PaneID != "acme/wN:pC" || p.Session != "acme" {
		t.Errorf("payload = %s, want acme-qualified pane_id + session=acme", e.Payload)
	}
}

func TestPaneUpdatedForwardsAndDerivesStatus(t *testing.T) {
	bus := events.New()
	sub := bus.Subscribe(16)
	defer sub.Close()
	ing := NewIngester(New(), bus)

	ing.handle(msg("pane_updated", samplerPaneUpdatedAgent))

	got := collect(t, sub, 2)
	if got[0].Type != events.TypePaneUpdated || got[0].Source != events.SourceHerdr {
		t.Errorf("first = %s/%s, want herdr/pane_updated", got[0].Source, got[0].Type)
	}
	if got[1].Type != events.TypePaneAgentStatusChanged {
		t.Fatalf("second = %s, want pane_agent_status_changed", got[1].Type)
	}
	var st struct {
		PaneID      string `json:"pane_id"`
		AgentStatus string `json:"agent_status"`
		Agent       string `json:"agent"`
	}
	if err := json.Unmarshal(got[1].Payload, &st); err != nil {
		t.Fatalf("unmarshal derived: %v", err)
	}
	if st.PaneID != "wN:pB" || st.AgentStatus != "idle" || st.Agent != "claude" {
		t.Errorf("derived status = %+v, want wN:pB/idle/claude", st)
	}
}

func TestDottedAgentStatusSynthesizedNotForwarded(t *testing.T) {
	bus := events.New()
	sub := bus.Subscribe(16)
	defer sub.Close()
	ing := NewIngester(New(), bus)

	ing.handle(msg("pane.agent_status_changed", samplerDottedAgentStatus))

	e := collect(t, sub, 1)[0]
	if e.Type != events.TypePaneAgentStatusChanged || e.Source != events.SourceHerdr {
		t.Fatalf("got %s/%s, want herdr/pane_agent_status_changed", e.Source, e.Type)
	}
	// The dotted event itself must NOT be forwarded verbatim (only one envelope).
	var st struct {
		AgentStatus string `json:"agent_status"`
	}
	json.Unmarshal(e.Payload, &st)
	if st.AgentStatus != "working" {
		t.Errorf("agent_status = %q, want working", st.AgentStatus)
	}
}

func TestAgentStatusDedup(t *testing.T) {
	bus := events.New()
	sub := bus.Subscribe(16)
	defer sub.Close()
	ing := NewIngester(New(), bus)

	// Same status arriving from two different signals collapses to one emit.
	ing.emitAgentStatus("wN:pB", "wN", "claude", "working")
	ing.emitAgentStatus("wN:pB", "wN", "claude", "working")
	ing.emitAgentStatus("wN:pB", "wN", "claude", "blocked") // real change

	got := collect(t, sub, 2)
	if got[0].Type != events.TypePaneAgentStatusChanged || got[1].Type != events.TypePaneAgentStatusChanged {
		t.Fatalf("types = %s,%s", got[0].Type, got[1].Type)
	}
	var a, b struct {
		AgentStatus string `json:"agent_status"`
	}
	json.Unmarshal(got[0].Payload, &a)
	json.Unmarshal(got[1].Payload, &b)
	if a.AgentStatus != "working" || b.AgentStatus != "blocked" {
		t.Errorf("statuses = %q,%q, want working,blocked", a.AgentStatus, b.AgentStatus)
	}
}

func TestPaneAgentDetectedDerivesStatus(t *testing.T) {
	bus := events.New()
	sub := bus.Subscribe(16)
	defer sub.Close()
	ing := NewIngester(New(), bus)

	ing.handle(msg("pane_agent_detected", samplerPaneAgentDetected))

	got := collect(t, sub, 2) // verbatim + derived
	if got[0].Type != events.TypePaneAgentDetected {
		t.Errorf("first = %s, want pane_agent_detected", got[0].Type)
	}
	if got[1].Type != events.TypePaneAgentStatusChanged {
		t.Errorf("second = %s, want pane_agent_status_changed", got[1].Type)
	}
}

// ingesterWith builds an Ingester whose published-status baseline is `seen`.
func ingesterWith(seen map[string]string) *Ingester {
	i := NewIngester(nil, events.New())
	for pane, status := range seen {
		i.lastStatus[pane] = status
	}
	return i
}

// TestLivenessProbeAgreementIsNotStale: while what we published matches Herdr,
// the subscription is delivering and must be left alone. Silence on its own is
// NOT evidence of trouble — an idle Herdr is legitimately quiet for long
// stretches, and reconnecting on quiet would churn the socket on any machine
// nobody is using.
func TestLivenessProbeAgreementIsNotStale(t *testing.T) {
	i := ingesterWith(map[string]string{"wN:p1": "idle", "wN:p2": "working"})

	agents := []Agent{
		{PaneID: "wN:p1", Status: "idle"},
		{PaneID: "wN:p2", Status: "working"},
	}
	if i.staleAgainst(agents) {
		t.Error("agreement reported as stale; a quiet subscription would be reconnected in a loop")
	}
	// No agents at all is agreement too, not a reason to reconnect.
	if i.staleAgainst(nil) {
		t.Error("an empty agent list reported as stale")
	}
}

// TestLivenessProbeDetectsMissedTransition is the failure this exists for: the
// subscription reported success and then delivered nothing, so Herdr moved on
// while our published view stayed frozen.
func TestLivenessProbeDetectsMissedTransition(t *testing.T) {
	i := ingesterWith(map[string]string{"wN:p1": "idle"})

	agents := []Agent{{PaneID: "wN:p1", Status: "blocked"}}
	if !i.staleAgainst(agents) {
		t.Error("a status Herdr changed without telling us was not detected")
	}
}

// TestLivenessProbeDetectsUnseenPane: a pane Herdr knows about that we never
// published means its pane_created/agent_detected never arrived.
func TestLivenessProbeDetectsUnseenPane(t *testing.T) {
	i := ingesterWith(map[string]string{"wN:p1": "idle"})

	agents := []Agent{
		{PaneID: "wN:p1", Status: "idle"},
		{PaneID: "wN:p9", Status: "idle"}, // never seen
	}
	if !i.staleAgainst(agents) {
		t.Error("an agent pane we never published was not detected")
	}
}

// TestLivenessProbeIgnoresClosedPanes: our baseline may still hold panes Herdr
// has dropped. That is not evidence of a dead subscription — the close event may
// simply be what we are about to receive — and must not force a reconnect.
func TestLivenessProbeIgnoresClosedPanes(t *testing.T) {
	i := ingesterWith(map[string]string{"wN:p1": "idle", "wN:pGone": "working"})

	agents := []Agent{{PaneID: "wN:p1", Status: "idle"}}
	if i.staleAgainst(agents) {
		t.Error("a pane missing from Herdr's list reported as stale")
	}
}

// TestLivenessProbeIgnoresDriftWhileEventsFlow is the regression test for a
// false positive that resubscribed the socket every 60 seconds in production.
//
// The snapshot and the event stream are sampled at different instants, so an
// agent that is actively working differs between them almost constantly.
// Treating that as proof of a dead subscription made a BUSY machine — the exact
// case the ingester exists for — tear its socket down in a loop. Disagreement
// only counts once the socket has also gone quiet.
func TestLivenessProbeIgnoresDriftWhileEventsFlow(t *testing.T) {
	i := ingesterWith(map[string]string{"wN:p1": "idle"})
	i.sawEvent() // something arrived just now

	// Herdr has moved on, and we disagree — but events are still flowing.
	if i.silentFor(probeSilence) {
		t.Fatal("a socket that just delivered is reported as silent")
	}
	if i.stale() {
		t.Error("drift treated as a dead subscription while events are arriving")
	}
}

// TestLivenessProbeNeedsSilence: the silence gate is what makes drift meaningful.
func TestLivenessProbeNeedsSilence(t *testing.T) {
	i := ingesterWith(map[string]string{"wN:p1": "idle"})

	i.sawEvent()
	if i.silentFor(time.Millisecond * 50) {
		t.Error("reported silent immediately after an event")
	}

	i.mu.Lock()
	i.lastEventAt = time.Now().Add(-2 * probeSilence)
	i.mu.Unlock()
	if !i.silentFor(probeSilence) {
		t.Error("a socket quiet for twice the window is not reported silent")
	}
}
