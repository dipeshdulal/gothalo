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
