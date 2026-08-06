package server

import (
	"encoding/json"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/transcript"
)

// fakeSource is a Source whose reads are canned, so the stream/framing logic can
// be exercised without a transcript on disk. It records Close so a swap can be
// checked for leaking the source it replaced.
type fakeSource struct {
	id      string
	backlog transcript.Backlog
	older   transcript.OlderPage
	poll    []transcript.Entry
	closed  int
}

func (f *fakeSource) Backlog(int) (transcript.Backlog, error)      { return f.backlog, nil }
func (f *fakeSource) Older(int, int) (transcript.OlderPage, error) { return f.older, nil }
func (f *fakeSource) Poll() ([]transcript.Entry, error)            { return f.poll, nil }
func (f *fakeSource) Close() error                                 { f.closed++; return nil }

// A session rotation must hand every subsequent read to the new source and close
// the old one exactly once — the socket outlives the session, so a leaked source
// here is a source leaked per /clear, for the life of the connection.
func TestTranscriptStreamSwapClosesPreviousAndRedirectsReads(t *testing.T) {
	old := &fakeSource{id: "old", poll: []transcript.Entry{{Text: "from old"}}}
	next := &fakeSource{id: "new", poll: []transcript.Entry{{Text: "from new"}}}

	stream := &transcriptStream{src: old, sessionID: "session-a"}
	if got := stream.SessionID(); got != "session-a" {
		t.Fatalf("SessionID = %q, want session-a", got)
	}

	previous := stream.Swap(next, "session-b")
	if previous != "session-a" {
		t.Fatalf("Swap returned %q, want the previous session id session-a", previous)
	}
	if old.closed != 1 {
		t.Fatalf("previous source closed %d times, want 1", old.closed)
	}
	if next.closed != 0 {
		t.Fatalf("adopted source was closed %d times, want 0", next.closed)
	}
	if got := stream.SessionID(); got != "session-b" {
		t.Fatalf("SessionID after swap = %q, want session-b", got)
	}

	ents, err := stream.Poll()
	if err != nil {
		t.Fatalf("Poll: %v", err)
	}
	if len(ents) != 1 || ents[0].Text != "from new" {
		t.Fatalf("Poll read from the wrong source: %+v", ents)
	}

	if err := stream.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if next.closed != 1 {
		t.Fatalf("current source closed %d times after stream Close, want 1", next.closed)
	}
}

// sendOpening is what a client sees both on connect and after a rotation, so the
// order and the session id it carries are the contract.
func TestSendOpeningFramesInOrder(t *testing.T) {
	var frames []map[string]any
	send := func(v any) error {
		b, err := json.Marshal(v)
		if err != nil {
			return err
		}
		var m map[string]any
		if err := json.Unmarshal(b, &m); err != nil {
			return err
		}
		frames = append(frames, m)
		return nil
	}

	backlog := transcript.Backlog{
		Entries:   []transcript.Entry{{Seq: 4, Text: "a"}, {Seq: 5, Text: "b"}},
		Total:     5,
		OldestSeq: 4,
		HasMore:   true,
	}
	opening := transcriptOpening{pane: "w1:p1", kind: "claude", sessionID: "session-b"}
	if err := sendOpening(send, opening, backlog); err != nil {
		t.Fatalf("sendOpening: %v", err)
	}

	want := []string{"hello", "entry", "entry", "backlog_complete"}
	if len(frames) != len(want) {
		t.Fatalf("got %d frames, want %d: %+v", len(frames), len(want), frames)
	}
	for i, typ := range want {
		if frames[i]["type"] != typ {
			t.Fatalf("frame %d type = %v, want %s", i, frames[i]["type"], typ)
		}
	}

	hello := frames[0]
	if hello["session_id"] != "session-b" {
		t.Fatalf("hello.session_id = %v, want session-b", hello["session_id"])
	}
	if hello["protocol"] != float64(transcriptProtocol) {
		t.Fatalf("hello.protocol = %v, want %d", hello["protocol"], transcriptProtocol)
	}
	if hello["oldest_loaded_seq"] != float64(4) || hello["has_older"] != true {
		t.Fatalf("hello pagination stats wrong: %+v", hello)
	}
	// Backlog entries are replayed, never live — a client that treats them as the
	// live tail would auto-scroll through the whole page.
	if frames[1]["live"] != false {
		t.Fatalf("backlog entry marked live: %+v", frames[1])
	}
	if frames[3]["count"] != float64(2) {
		t.Fatalf("backlog_complete.count = %v, want 2", frames[3]["count"])
	}
}

// The roster belongs to the session, so the hello a rotation sends must carry the
// NEW session's roster — and never a subagent, since a ?subagent= stream does not
// follow rotations at all.
func TestOpenedSessionOpeningCarriesNewRosterAndNoSubagent(t *testing.T) {
	opened := openedSession{
		sessionID: "session-b",
		kind:      "claude",
		subagents: []transcript.Subagent{{AgentID: "aa4832e5ce82b16f0"}},
	}

	op := opened.opening("w1:p1")
	if op.pane != "w1:p1" || op.kind != "claude" || op.sessionID != "session-b" {
		t.Fatalf("opening identity wrong: %+v", op)
	}
	if op.subagent != "" {
		t.Fatalf("opening.subagent = %q, want empty — a rotation is always a root transcript", op.subagent)
	}
	if len(op.subagents) != 1 || op.subagents[0].AgentID != "aa4832e5ce82b16f0" {
		t.Fatalf("opening did not carry the new session's roster: %+v", op.subagents)
	}
}
