package events

import (
	"encoding/json"
	"testing"
	"time"
)

func drain(t *testing.T, s *Sub, want int) []Envelope {
	t.Helper()
	var got []Envelope
	timeout := time.After(time.Second)
	for len(got) < want {
		select {
		case e, ok := <-s.C():
			if !ok {
				t.Fatalf("channel closed after %d/%d envelopes", len(got), want)
			}
			got = append(got, e)
		case <-timeout:
			t.Fatalf("timed out after %d/%d envelopes", len(got), want)
		}
	}
	return got
}

func TestPublishFanOutAndSeq(t *testing.T) {
	b := New()
	a := b.Subscribe(8)
	c := b.Subscribe(8)
	defer a.Close()
	defer c.Close()

	for i := 0; i < 3; i++ {
		if _, err := b.Publish(SourceGothalo, TypePushSent, map[string]int{"n": i}); err != nil {
			t.Fatalf("publish: %v", err)
		}
	}

	for _, s := range []*Sub{a, c} {
		got := drain(t, s, 3)
		for i, e := range got {
			if e.Seq != uint64(i+1) {
				t.Errorf("envelope %d seq = %d, want %d", i, e.Seq, i+1)
			}
			if e.Source != SourceGothalo || e.Type != TypePushSent {
				t.Errorf("envelope %d = %s/%s, want gothalo/push_sent", i, e.Source, e.Type)
			}
			if e.TS == 0 {
				t.Errorf("envelope %d has zero ts", i)
			}
		}
	}
	if b.CurrentSeq() != 3 {
		t.Errorf("CurrentSeq = %d, want 3", b.CurrentSeq())
	}
}

func TestPayloadRoundTrip(t *testing.T) {
	b := New()
	s := b.Subscribe(4)
	defer s.Close()

	type body struct {
		Pane    string `json:"pane"`
		Applied bool   `json:"applied"`
	}
	b.Publish(SourceGothalo, TypeApproveApplied, body{Pane: "wN:p2", Applied: true})

	e := drain(t, s, 1)[0]
	var got body
	if err := json.Unmarshal(e.Payload, &got); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	if got.Pane != "wN:p2" || !got.Applied {
		t.Errorf("payload = %+v, want {wN:p2 true}", got)
	}
}

func TestRawMessagePayloadPassthrough(t *testing.T) {
	b := New()
	s := b.Subscribe(4)
	defer s.Close()

	// A Herdr event forwards its data object verbatim as a json.RawMessage.
	raw := json.RawMessage(`{"type":"pane_focused","pane_id":"wN:pC","workspace_id":"wN"}`)
	b.Publish(SourceHerdr, TypePaneFocused, raw)

	e := drain(t, s, 1)[0]
	if string(e.Payload) != string(raw) {
		t.Errorf("payload = %s, want %s", e.Payload, raw)
	}
}

func TestSlowSubscriberDroppedNotBlocking(t *testing.T) {
	b := New()
	slow := b.Subscribe(2) // tiny buffer, never drained
	fast := b.Subscribe(64)
	defer slow.Close()
	defer fast.Close()

	// Publish more than the slow subscriber's buffer. This must not block.
	const n = 20
	done := make(chan struct{})
	go func() {
		for i := 0; i < n; i++ {
			b.Publish(SourceHerdr, TypePaneUpdated, map[string]int{"i": i})
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Publish blocked on a slow subscriber")
	}

	// The fast subscriber still received everything, in order.
	got := drain(t, fast, n)
	for i, e := range got {
		if e.Seq != uint64(i+1) {
			t.Errorf("fast seq[%d] = %d, want %d", i, e.Seq, i+1)
		}
	}

	// The slow subscriber's channel is closed and marked dropped.
	// Drain whatever buffered, then confirm closed.
	closed := false
	for range slow.C() {
	}
	// Range exits when the channel is closed.
	closed = true
	if !closed || !slow.Dropped() {
		t.Errorf("slow subscriber: closed=%v dropped=%v, want closed+dropped", closed, slow.Dropped())
	}
}

func TestCloseUnregisters(t *testing.T) {
	b := New()
	s := b.Subscribe(4)
	if b.SubscriberCount() != 1 {
		t.Fatalf("SubscriberCount = %d, want 1", b.SubscriberCount())
	}
	s.Close()
	if b.SubscriberCount() != 0 {
		t.Fatalf("SubscriberCount after close = %d, want 0", b.SubscriberCount())
	}
	s.Close() // idempotent, must not panic
	// Publishing after all subscribers left is a no-op that still advances seq.
	if _, err := b.Publish(SourceHerdr, TypeLayoutUpdated, nil); err != nil {
		t.Fatalf("publish after close: %v", err)
	}
}
