package transcript

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// newOpencodeDB builds a throwaway opencode.db under a temp $OPENCODE_DATA_DIR,
// mirroring the live schema closely enough to exercise the message/part join.
func newOpencodeDB(t *testing.T) (dir, sessionID string) {
	t.Helper()
	dir = t.TempDir()
	t.Setenv("OPENCODE_DATA_DIR", dir)

	db, err := sql.Open("sqlite", filepath.Join(dir, "opencode.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if _, err := db.Exec(`
		CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT);
		CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
		                      time_created INTEGER NOT NULL, data TEXT NOT NULL);
		CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
		                   time_created INTEGER NOT NULL, data TEXT NOT NULL);`); err != nil {
		t.Fatal(err)
	}
	sessionID = "ses_test0000000000000000001"
	if _, err := db.Exec(
		`INSERT INTO session (id, directory, title) VALUES (?, '/tmp/proj', 'test')`,
		sessionID); err != nil {
		t.Fatal(err)
	}
	return dir, sessionID
}

func addMessage(t *testing.T, dir, sessionID, msgID, role string, created int64) {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(dir, "opencode.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	data := `{"role":"` + role + `","time":{"created":` + itoa(created) + `}}`
	if _, err := db.Exec(
		`INSERT INTO message (id, session_id, time_created, data) VALUES (?,?,?,?)`,
		msgID, sessionID, created, data); err != nil {
		t.Fatal(err)
	}
}

func addPart(t *testing.T, dir, sessionID, partID, msgID, data string) {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(dir, "opencode.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(
		`INSERT INTO part (id, message_id, session_id, time_created, data) VALUES (?,?,?,?,?)`,
		partID, msgID, sessionID, 1, data); err != nil {
		t.Fatal(err)
	}
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

// TestOpencodeSourceEndToEnd covers the part shapes captured from a live store:
// text, reasoning, a completed bash call, a completed edit (whose diff rides on
// state.metadata), a failed call, an in-flight call, and the turn plumbing that
// must be dropped.
func TestOpencodeSourceEndToEnd(t *testing.T) {
	dir, sess := newOpencodeDB(t)

	addMessage(t, dir, sess, "msg_001", "user", 1700000000000)
	addPart(t, dir, sess, "prt_001", "msg_001", `{"type":"text","text":"hello"}`)

	addMessage(t, dir, sess, "msg_002", "assistant", 1700000001000)
	addPart(t, dir, sess, "prt_002", "msg_002", `{"type":"step-start","snapshot":"abc"}`)
	addPart(t, dir, sess, "prt_003", "msg_002", `{"type":"reasoning","text":"thinking about it"}`)
	addPart(t, dir, sess, "prt_004", "msg_002",
		`{"type":"tool","tool":"bash","callID":"c1","state":{"status":"completed",`+
			`"title":"run it","input":{"command":"git status"},"output":"On branch main"}}`)
	addPart(t, dir, sess, "prt_005", "msg_002",
		`{"type":"tool","tool":"edit","callID":"c2","state":{"status":"completed",`+
			`"input":{"filePath":"/tmp/proj/README.md"},"output":"Edit applied successfully.",`+
			`"metadata":{"diff":"--- a\n+++ b\n+added\n"}}}`)
	addPart(t, dir, sess, "prt_006", "msg_002",
		`{"type":"tool","tool":"question","callID":"c3","state":{"status":"error",`+
			`"input":{},"error":"The user dismissed this question"}}`)
	addPart(t, dir, sess, "prt_007", "msg_002",
		`{"type":"tool","tool":"read","callID":"c4","state":{"status":"running","input":{"filePath":"/tmp/x"}}}`)
	addPart(t, dir, sess, "prt_008", "msg_002", `{"type":"step-finish","reason":"stop"}`)
	addPart(t, dir, sess, "prt_009", "msg_002", `{"type":"patch","hash":"h","files":["/tmp/a"]}`)
	addPart(t, dir, sess, "prt_010", "msg_002", `{"type":"text","text":"done"}`)

	src, err := Open("opencode", "", sess)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer src.Close()

	b, err := src.Backlog(100)
	if err != nil {
		t.Fatalf("Backlog: %v", err)
	}

	// text, reasoning, bash call+result, edit call+result, question call+result,
	// read call (running, no result), text. step-*/patch dropped.
	wantKinds := []string{
		KindMessage,    // hello
		KindThinking,   // thinking about it
		KindToolCall,   // bash
		KindToolResult, // bash result
		KindToolCall,   // edit
		KindToolResult, // edit result
		KindToolCall,   // question
		KindToolResult, // question error
		KindToolCall,   // read, still running -> NO result
		KindMessage,    // done
	}
	if len(b.Entries) != len(wantKinds) {
		var got []string
		for _, e := range b.Entries {
			got = append(got, e.Kind)
		}
		t.Fatalf("got %d entries %v, want %d %v", len(b.Entries), got, len(wantKinds), wantKinds)
	}
	for i, w := range wantKinds {
		if b.Entries[i].Kind != w {
			t.Errorf("entry %d kind = %q, want %q", i, b.Entries[i].Kind, w)
		}
	}

	// bash projects its command; the result carries the output and is OK.
	if tool := b.Entries[2].Tool; tool == nil || tool.Command != "git status" || tool.Name != "bash" {
		t.Errorf("bash call = %+v, want name bash / command 'git status'", b.Entries[2].Tool)
	}
	if r := b.Entries[3].Result; r == nil || !r.OK || r.ForID != "c1" || r.OutputSummary != "On branch main" {
		t.Errorf("bash result = %+v", b.Entries[3].Result)
	}

	// edit projects its file, and the diff rides on the RESULT (from state.metadata).
	if tool := b.Entries[4].Tool; tool == nil || tool.File != "/tmp/proj/README.md" {
		t.Errorf("edit call = %+v, want file set", b.Entries[4].Tool)
	}
	if r := b.Entries[5].Result; r == nil || r.Diff == "" {
		t.Errorf("edit result = %+v, want a diff from state.metadata.diff", b.Entries[5].Result)
	}

	// A failed call reports OK=false and surfaces the error text.
	if r := b.Entries[7].Result; r == nil || r.OK ||
		r.OutputSummary != "The user dismissed this question" {
		t.Errorf("failed result = %+v, want OK=false with the error text", b.Entries[7].Result)
	}

	// An in-flight call emits the invocation only — there is no outcome yet.
	if b.Entries[8].Tool == nil || b.Entries[8].Tool.Name != "read" {
		t.Errorf("running call = %+v, want the read invocation", b.Entries[8].Tool)
	}

	// Roles come from the parent message, not the part.
	if b.Entries[0].Role != "user" || b.Entries[1].Role != "assistant" {
		t.Errorf("roles = %q/%q, want user/assistant", b.Entries[0].Role, b.Entries[1].Role)
	}

	// Poll is quiet, then picks up a new part exactly once.
	if ents, err := src.Poll(); err != nil || len(ents) != 0 {
		t.Fatalf("Poll before insert = %d, err %v", len(ents), err)
	}
	addPart(t, dir, sess, "prt_011", "msg_002", `{"type":"text","text":"more"}`)
	ents, err := src.Poll()
	if err != nil || len(ents) != 1 {
		t.Fatalf("Poll after insert = %d, err %v; want 1", len(ents), err)
	}
	if ents2, _ := src.Poll(); len(ents2) != 0 {
		t.Errorf("second Poll = %d, want 0 (no replay)", len(ents2))
	}
}

// TestOpencodeOlderPaging: seq counts ENTRIES, and a settled tool part yields two
// of them, so paging must not assume one entry per row.
func TestOpencodeOlderPaging(t *testing.T) {
	dir, sess := newOpencodeDB(t)
	addMessage(t, dir, sess, "msg_001", "assistant", 1700000000000)
	// 2 text + one settled tool (2 entries) = 4 entries from 3 rows.
	addPart(t, dir, sess, "prt_001", "msg_001", `{"type":"text","text":"one"}`)
	addPart(t, dir, sess, "prt_002", "msg_001",
		`{"type":"tool","tool":"bash","callID":"c1","state":{"status":"completed","input":{"command":"ls"},"output":"x"}}`)
	addPart(t, dir, sess, "prt_003", "msg_001", `{"type":"text","text":"two"}`)

	src, err := Open("opencode", "", sess)
	if err != nil {
		t.Fatal(err)
	}
	defer src.Close()

	b, err := src.Backlog(2)
	if err != nil {
		t.Fatal(err)
	}
	if b.Total != 4 {
		t.Fatalf("Total = %d, want 4 (a settled tool row is two entries)", b.Total)
	}
	if b.OldestSeq != 3 || !b.HasMore {
		t.Fatalf("oldest=%d hasMore=%v, want 3/true", b.OldestSeq, b.HasMore)
	}

	page, err := src.Older(b.OldestSeq, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Entries) != 2 || page.OldestSeq != 1 || page.HasOlder {
		t.Fatalf("older: n=%d oldest=%d hasOlder=%v; want 2/1/false",
			len(page.Entries), page.OldestSeq, page.HasOlder)
	}
}

func TestOpencodeOpenErrors(t *testing.T) {
	newOpencodeDB(t)
	if _, err := Open("opencode", "", ""); err != ErrNoTranscript {
		t.Errorf("empty session: %v, want ErrNoTranscript", err)
	}
	if _, err := Open("opencode", "", "ses_nope"); err != ErrNoTranscript {
		t.Errorf("unknown session: %v, want ErrNoTranscript", err)
	}
}

// TestOpencodeReaderDegrades: malformed rows must not break the stream.
func TestOpencodeReaderDegrades(t *testing.T) {
	// An unknown part type passes through flagged rather than vanishing.
	ents := (opencodeReader{}).Normalize([]byte(
		`{"id":"p1","message_id":"m1","message_data":{"role":"assistant"},"part_data":{"type":"future-thing","text":"hi"}}`))
	if len(ents) != 1 || ents[0].Parsed {
		t.Errorf("unknown part type = %+v, want one Parsed=false entry", ents)
	}

	// Unparseable JSON still yields something.
	bad := (opencodeReader{}).Normalize([]byte(`{{{`))
	if len(bad) != 1 || bad[0].Parsed {
		t.Errorf("unparseable = %+v, want one Parsed=false entry", bad)
	}

	// Turn plumbing is dropped outright.
	for _, typ := range []string{"step-start", "step-finish", "patch"} {
		got := (opencodeReader{}).Normalize([]byte(
			`{"id":"p1","message_id":"m1","message_data":{"role":"assistant"},"part_data":{"type":"` + typ + `"}}`))
		if len(got) != 0 {
			t.Errorf("%s = %+v, want dropped", typ, got)
		}
	}
}
