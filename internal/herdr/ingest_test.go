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

func TestForwardsGlobalEventVerbatim(t *testing.T) {
	bus := events.New()
	sub := bus.Subscribe(16)
	defer sub.Close()
	ing := NewIngester(New(), bus)

	ing.handle(msg("pane_focused", samplerPaneFocused))

	e := collect(t, sub, 1)[0]
	if e.Source != events.SourceHerdr || e.Type != events.TypePaneFocused {
		t.Fatalf("got %s/%s, want herdr/pane_focused", e.Source, e.Type)
	}
	if string(e.Payload) != samplerPaneFocused {
		t.Errorf("payload = %s, want verbatim data", e.Payload)
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
