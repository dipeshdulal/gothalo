package transcript

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestOpenClaudeSource exercises the Source seam end to end for the file-backed
// backend: Open resolves a real transcript, Backlog pages it, Older cursors back
// through it, and Poll picks up an append. These are the exact four calls
// internal/server/transcript.go makes, so a backend that satisfies them plugs in
// without the endpoint changing — which is the point of the abstraction.
func TestOpenClaudeSource(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cwd := "/Users/dev/projects/demo"
	dir := filepath.Join(home, ".claude", "projects", EncodeProjectDir(cwd))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	sess := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	path := filepath.Join(dir, sess+".jsonl")

	msg := func(role, text string) string {
		return `{"type":"` + role + `","cwd":"` + cwd + `","message":{"role":"` + role +
			`","content":"` + text + `"}}` + "\n"
	}
	var b strings.Builder
	for _, m := range []string{"one", "two", "three", "four"} {
		b.WriteString(msg("user", m))
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	src, err := Open("claude", cwd, sess)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer src.Close()

	// Backlog: newest page, absolute seqs stamped.
	backlog, err := src.Backlog(2)
	if err != nil {
		t.Fatalf("Backlog: %v", err)
	}
	if backlog.Total != 4 {
		t.Errorf("Total = %d, want 4", backlog.Total)
	}
	if len(backlog.Entries) != 2 {
		t.Fatalf("page = %d entries, want 2", len(backlog.Entries))
	}
	if !backlog.HasMore {
		t.Error("HasMore = false, want true (2 of 4 elided)")
	}
	if backlog.OldestSeq != 3 {
		t.Errorf("OldestSeq = %d, want 3", backlog.OldestSeq)
	}
	if got := backlog.Entries[1].Seq; got != 4 {
		t.Errorf("newest entry Seq = %d, want 4", got)
	}

	// Older: page back from the backlog's cursor.
	page, err := src.Older(backlog.OldestSeq, 10)
	if err != nil {
		t.Fatalf("Older: %v", err)
	}
	if len(page.Entries) != 2 {
		t.Fatalf("older page = %d entries, want 2", len(page.Entries))
	}
	if page.OldestSeq != 1 {
		t.Errorf("older OldestSeq = %d, want 1", page.OldestSeq)
	}
	if page.HasOlder {
		t.Error("HasOlder = true, want false at the head of the session")
	}

	// Poll: nothing new yet, then an append shows up exactly once.
	if ents, err := src.Poll(); err != nil || len(ents) != 0 {
		t.Fatalf("Poll before append = %d entries, err %v; want 0, nil", len(ents), err)
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(msg("user", "five")); err != nil {
		t.Fatal(err)
	}
	f.Close()

	ents, err := src.Poll()
	if err != nil {
		t.Fatalf("Poll after append: %v", err)
	}
	if len(ents) != 1 {
		t.Fatalf("Poll after append = %d entries, want 1", len(ents))
	}
	if ents2, err := src.Poll(); err != nil || len(ents2) != 0 {
		t.Errorf("second Poll = %d entries, err %v; want 0, nil (no replay)", len(ents2), err)
	}
}

// TestPendingClaudeTranscript covers a brand-new agent: herdr knows its session
// id, but Claude writes the .jsonl lazily so nothing is on disk yet.
//
// That must open as an EMPTY transcript rather than fail. Failing 404s a healthy
// pane, which the app can only render as an error — and because Dart's WebSocket
// client reports a rejected upgrade without an HTTP status, it showed up as an
// endless spinner. The source instead waits at the path the file will occupy and
// streams entries the moment Claude creates it.
func TestPendingClaudeTranscript(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cwd := "/Users/dev/projects/demo"
	dir := filepath.Join(home, ".claude", "projects", EncodeProjectDir(cwd))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	sess := "cccccccc-dddd-eeee-ffff-000000000000"

	// No file for this session — the agent has not spoken.
	src, err := Open("claude", cwd, sess)
	if err != nil {
		t.Fatalf("Open on a not-yet-written transcript: %v, want a pending source", err)
	}
	defer src.Close()

	b, err := src.Backlog(50)
	if err != nil {
		t.Fatalf("Backlog: %v", err)
	}
	if b.Total != 0 || len(b.Entries) != 0 || b.HasMore {
		t.Fatalf("backlog = %+v, want empty", b)
	}
	if ents, err := src.Poll(); err != nil || len(ents) != 0 {
		t.Fatalf("Poll before the file exists = %d, err %v; want 0, nil", len(ents), err)
	}
	if page, err := src.Older(1, 10); err != nil || len(page.Entries) != 0 {
		t.Fatalf("Older before the file exists = %d, err %v; want 0, nil", len(page.Entries), err)
	}

	// Claude writes the first message — it must stream without reconnecting.
	line := `{"type":"user","cwd":"` + cwd + `","message":{"role":"user","content":"hello"}}` + "\n"
	if err := os.WriteFile(filepath.Join(dir, sess+".jsonl"), []byte(line), 0o644); err != nil {
		t.Fatal(err)
	}
	ents, err := src.Poll()
	if err != nil {
		t.Fatalf("Poll after the file appeared: %v", err)
	}
	if len(ents) != 1 {
		t.Fatalf("Poll after the file appeared = %d entries, want 1", len(ents))
	}
}

// TestUnknownSessionStillFails: the pending path must not swallow a genuinely
// unresolvable transcript. With no session id there is no path worth waiting on,
// so the caller should still get an error to 404 on.
func TestUnknownSessionStillFails(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	if _, err := Open("claude", "/Users/dev/projects/nope", ""); err == nil {
		t.Error("Open with no session id and no transcript: err = nil, want an error")
	}
}

// TestOpenUnsupportedKind: a kind with no registered opener must be reported as
// unsupported rather than silently yielding an empty stream, so the endpoint can
// 404 with a clear message.
func TestOpenUnsupportedKind(t *testing.T) {
	for _, kind := range []string{"codex", "opencode", "some-future-agent", ""} {
		if _, err := Open(kind, "/tmp/x", "sid"); err == nil {
			t.Errorf("Open(%q) err = nil, want ErrUnsupportedKind", kind)
		}
	}
}

// TestPollBeforeBacklog guards the ordering contract: Poll before Backlog must
// return nothing rather than panic on an unarmed cursor.
func TestPollBeforeBacklog(t *testing.T) {
	s := newFileSource("/nonexistent/transcript.jsonl", claudeReader{})
	ents, err := s.Poll()
	if err != nil || len(ents) != 0 {
		t.Errorf("Poll before Backlog = %d entries, err %v; want 0, nil", len(ents), err)
	}
}
