package transcript

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReaderRegistry(t *testing.T) {
	if ReaderFor("claude").Kind() != "claude" {
		t.Error("claude reader not registered")
	}
	// Stub kinds are registered (the one-file extensibility seam), proving
	// ReaderFor routes to them rather than the bare generic fallback.
	for _, k := range []string{"codex", "opencode"} {
		if _, ok := registry[k]; !ok {
			t.Errorf("kind %q not registered", k)
		}
	}
	// Unknown kind -> generic fallback (Kind == "").
	if ReaderFor("totally-unknown").Kind() != "" {
		t.Error("unknown kind did not fall back to generic reader")
	}
}

func TestGenericReaderParsedFalse(t *testing.T) {
	g := genericReader{}
	got := g.Normalize([]byte(`{"uuid":"z1","timestamp":"2026-01-01T00:00:00Z","text":"hello there"}`))
	if len(got) != 1 {
		t.Fatalf("got %d entries, want 1", len(got))
	}
	if got[0].Parsed {
		t.Error("generic reader Parsed=true, want false")
	}
	if got[0].Text != "hello there" || got[0].ID != "z1" {
		t.Errorf("generic entry = %+v, want text/id filled", got[0])
	}
	// Non-JSON still yields exactly one Parsed=false entry (never drops).
	if bad := g.Normalize([]byte("not json")); len(bad) != 1 || bad[0].Parsed {
		t.Errorf("generic non-JSON = %+v, want 1 Parsed=false", bad)
	}
}

func TestReadBacklogCapAndHasMore(t *testing.T) {
	path := filepath.Join("testdata", "claude_sample.jsonl")
	r := ReaderFor("claude")

	// Large cap: everything fits, HasMore false.
	full, offset, err := ReadBacklog(path, r, DefaultBacklogCap)
	if err != nil {
		t.Fatal(err)
	}
	if full.HasMore {
		t.Error("HasMore=true with a large cap")
	}
	if full.Total != len(full.Entries) {
		t.Errorf("Total=%d but returned %d entries (nothing should be dropped)", full.Total, len(full.Entries))
	}
	if offset <= 0 {
		t.Errorf("resume offset = %d, want > 0", offset)
	}

	// Small cap: only the last N kept, HasMore true, entries are the newest.
	const cap = 3
	small, _, err := ReadBacklog(path, r, cap)
	if err != nil {
		t.Fatal(err)
	}
	if len(small.Entries) != cap {
		t.Errorf("len = %d, want %d", len(small.Entries), cap)
	}
	if !small.HasMore {
		t.Error("HasMore=false with a small cap")
	}
	// The last entry of the capped backlog must equal the last of the full one.
	if small.Entries[len(small.Entries)-1].ID != full.Entries[len(full.Entries)-1].ID {
		t.Error("capped backlog did not keep the newest entries")
	}
}

func TestTailerPicksUpAppends(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("testdata", "claude_sample.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	tmp := filepath.Join(t.TempDir(), "live.jsonl")
	if err := os.WriteFile(tmp, src, 0o644); err != nil {
		t.Fatal(err)
	}
	r := ReaderFor("claude")

	_, offset, err := ReadBacklog(tmp, r, DefaultBacklogCap)
	if err != nil {
		t.Fatal(err)
	}
	tailer := NewTailer(tmp, r, offset)

	// Nothing appended yet -> no entries.
	if ents, err := tailer.Poll(); err != nil || len(ents) != 0 {
		t.Fatalf("initial poll = %v, %v; want empty", ents, err)
	}

	// Append a new assistant message line; the tail should surface it.
	f, err := os.OpenFile(tmp, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	line := `{"type":"assistant","uuid":"live1","parentUuid":"a6","timestamp":"2026-08-02T10:05:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"A freshly appended line."}]}}` + "\n"
	if _, err := f.WriteString(line); err != nil {
		t.Fatal(err)
	}
	f.Close()

	ents, err := tailer.Poll()
	if err != nil {
		t.Fatal(err)
	}
	if len(ents) != 1 || ents[0].Text != "A freshly appended line." {
		t.Fatalf("tail after append = %+v, want the new message", ents)
	}
	// A second poll with no further appends returns nothing (offset advanced).
	if ents, err := tailer.Poll(); err != nil || len(ents) != 0 {
		t.Fatalf("second poll = %v, %v; want empty", ents, err)
	}
}

func TestDiffFromEditInput(t *testing.T) {
	diff, _ := diffFromEditInput("line one\nline two\nline three", "line one\nline TWO\nline three")
	if !strings.Contains(diff, "-line two") || !strings.Contains(diff, "+line TWO") {
		t.Errorf("diff did not capture the change:\n%s", diff)
	}
	// Context lines should be shared, not duplicated as -/+.
	if strings.Contains(diff, "-line one") || strings.Contains(diff, "+line one") {
		t.Errorf("context line rendered as a change:\n%s", diff)
	}
}
