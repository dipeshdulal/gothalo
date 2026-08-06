package transcript

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// newHermesDB builds a throwaway state.db with the columns hermesSource reads,
// under a temp $HERMES_DIR. The schema mirrors the live one closely enough to
// exercise the queries (session lookup, active filter, id ordering).
func newHermesDB(t *testing.T) (dir, sessionID string) {
	t.Helper()
	dir = t.TempDir()
	t.Setenv("HERMES_DIR", dir)

	db, err := sql.Open("sqlite", filepath.Join(dir, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if _, err := db.Exec(`
		CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, started_at REAL NOT NULL);
		CREATE TABLE messages (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			session_id TEXT NOT NULL,
			role TEXT NOT NULL,
			content TEXT,
			tool_call_id TEXT,
			tool_calls TEXT,
			tool_name TEXT,
			reasoning TEXT,
			timestamp REAL NOT NULL,
			active INTEGER NOT NULL DEFAULT 1
		);`); err != nil {
		t.Fatal(err)
	}

	sessionID = "20260804_134810_b832ba"
	if _, err := db.Exec(`INSERT INTO sessions (id, source, started_at) VALUES (?, 'cli', 1000)`, sessionID); err != nil {
		t.Fatal(err)
	}
	return dir, sessionID
}

func insertMsg(t *testing.T, dir, sessionID, role, content, toolCallID, toolCalls, reasoning string, active int) {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(dir, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(
		`INSERT INTO messages (session_id, role, content, tool_call_id, tool_calls, reasoning, timestamp, active)
		 VALUES (?,?,?,?,?,?,?,?)`,
		sessionID, role, content, toolCallID, toolCalls, reasoning, 1700000000.5, active); err != nil {
		t.Fatal(err)
	}
}

// TestHermesSourceEndToEnd drives a Hermes session through the same four Source
// calls the endpoint makes, asserting the row->entry expansion that makes seq
// differ from row id: one assistant row carrying reasoning + prose + a tool call
// becomes three entries.
func TestHermesSourceEndToEnd(t *testing.T) {
	dir, sess := newHermesDB(t)

	toolCalls := `[{"id":"c1","call_id":"c1","type":"function","function":{"name":"terminal","arguments":"{\"command\":\"ls -la\"}"}}]`
	insertMsg(t, dir, sess, "user", "hello", "", "", "", 1)                     // 1 entry
	insertMsg(t, dir, sess, "assistant", "sure", "", toolCalls, "thinking…", 1) // 3 entries
	insertMsg(t, dir, sess, "tool", "total 0", "c1", "", "", 1)                 // 1 entry
	insertMsg(t, dir, sess, "session_meta", "", "", "", "", 1)                  // dropped
	insertMsg(t, dir, sess, "user", "compacted away", "", "", "", 0)            // active=0, excluded

	src, err := Open("hermes", "", sess)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer src.Close()

	b, err := src.Backlog(100)
	if err != nil {
		t.Fatalf("Backlog: %v", err)
	}
	if b.Total != 5 {
		t.Fatalf("Total = %d, want 5 (1 user + 3 assistant + 1 tool; meta dropped, inactive excluded)", b.Total)
	}
	kinds := make([]string, len(b.Entries))
	for i, e := range b.Entries {
		kinds[i] = e.Kind
		if e.Seq != i+1 {
			t.Errorf("entry %d Seq = %d, want %d", i, e.Seq, i+1)
		}
	}
	want := []string{KindMessage, KindThinking, KindMessage, KindToolCall, KindToolResult}
	for i := range want {
		if kinds[i] != want[i] {
			t.Errorf("kind[%d] = %q, want %q (full: %v)", i, kinds[i], want[i], kinds)
		}
	}

	// The tool call keeps its id and projects `terminal`'s command, and the result
	// correlates back by that id.
	call := b.Entries[3]
	if call.Tool == nil || call.Tool.Name != "terminal" || call.Tool.Command != "ls -la" {
		t.Errorf("tool call = %+v, want terminal/ls -la", call.Tool)
	}
	res := b.Entries[4]
	if res.Result == nil || res.Result.ForID != "c1" || !res.Result.OK {
		t.Errorf("tool result = %+v, want ForID c1 and OK", res.Result)
	}

	// Poll is quiet until a row lands, then returns it exactly once.
	if ents, err := src.Poll(); err != nil || len(ents) != 0 {
		t.Fatalf("Poll before insert = %d, err %v; want 0, nil", len(ents), err)
	}
	insertMsg(t, dir, sess, "user", "more", "", "", "", 1)
	ents, err := src.Poll()
	if err != nil || len(ents) != 1 {
		t.Fatalf("Poll after insert = %d, err %v; want 1, nil", len(ents), err)
	}
	if ents2, _ := src.Poll(); len(ents2) != 0 {
		t.Errorf("second Poll = %d entries, want 0 (no replay)", len(ents2))
	}
}

// TestHermesOlderPaging: Older must page back through the *entry* stream, not the
// row stream, and report HasOlder correctly at the head.
func TestHermesOlderPaging(t *testing.T) {
	dir, sess := newHermesDB(t)
	for range 6 {
		insertMsg(t, dir, sess, "user", "msg", "", "", "", 1)
	}

	src, err := Open("hermes", "", sess)
	if err != nil {
		t.Fatal(err)
	}
	defer src.Close()

	b, err := src.Backlog(2)
	if err != nil {
		t.Fatal(err)
	}
	if b.Total != 6 || b.OldestSeq != 5 || !b.HasMore {
		t.Fatalf("backlog: total=%d oldest=%d hasMore=%v; want 6/5/true", b.Total, b.OldestSeq, b.HasMore)
	}

	page, err := src.Older(b.OldestSeq, 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Entries) != 3 || page.OldestSeq != 2 || !page.HasOlder {
		t.Fatalf("older: n=%d oldest=%d hasOlder=%v; want 3/2/true", len(page.Entries), page.OldestSeq, page.HasOlder)
	}

	head, err := src.Older(page.OldestSeq, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(head.Entries) != 1 || head.OldestSeq != 1 || head.HasOlder {
		t.Fatalf("head page: n=%d oldest=%d hasOlder=%v; want 1/1/false", len(head.Entries), head.OldestSeq, head.HasOlder)
	}
}

// TestHermesOpenErrors: the failure modes must be ErrNoTranscript so the endpoint
// answers 404 rather than opening a stream that never yields anything.
func TestHermesOpenErrors(t *testing.T) {
	dir, sess := newHermesDB(t)

	if _, err := Open("hermes", "", ""); err != ErrNoTranscript {
		t.Errorf("empty session id: err = %v, want ErrNoTranscript", err)
	}
	if _, err := Open("hermes", "", "no-such-session"); err != ErrNoTranscript {
		t.Errorf("unknown session: err = %v, want ErrNoTranscript", err)
	}

	if err := os.Remove(filepath.Join(dir, "state.db")); err != nil {
		t.Fatal(err)
	}
	if _, err := Open("hermes", "", sess); err != ErrNoTranscript {
		t.Errorf("missing db: err = %v, want ErrNoTranscript", err)
	}
}

// TestHermesReaderDegrades: a malformed tool_calls column must not break the
// stream — the row still yields its prose.
func TestHermesReaderDegrades(t *testing.T) {
	ents := (hermesReader{}).Normalize([]byte(
		`{"id":7,"role":"assistant","content":"still here","tool_calls":"{not json","timestamp":1700000000}`))
	if len(ents) != 1 || ents[0].Kind != KindMessage || ents[0].Text != "still here" {
		t.Fatalf("got %+v, want one message entry", ents)
	}

	// An unparseable row is passed through flagged rather than dropped.
	bad := (hermesReader{}).Normalize([]byte(`{{{`))
	if len(bad) != 1 || bad[0].Parsed {
		t.Errorf("unparseable row = %+v, want one Parsed=false entry", bad)
	}

	// A failed tool result is detected from Hermes's error prose.
	fail := (hermesReader{}).Normalize([]byte(
		`{"id":8,"role":"tool","content":"Error executing tool: boom","tool_call_id":"c9","timestamp":1700000000}`))
	if len(fail) != 1 || fail[0].Result == nil || fail[0].Result.OK {
		t.Fatalf("failed tool result = %+v, want OK=false", fail)
	}
}
