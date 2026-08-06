package transcript

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The age this reports is the difference between "blocked" and "blocked 50m",
// which is the whole reason to look. Two properties matter: it must come from
// what the agent WROTE (not from when the file was touched), and it must report
// nothing rather than something wrong.

func writeJSONL(t *testing.T, lines ...string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "s.jsonl")
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	return p
}

func entry(ts string) string {
	return fmt.Sprintf(`{"type":"assistant","timestamp":%q,"message":{"role":"assistant"}}`, ts)
}

func TestLastEntryTimeTakesTheNewest(t *testing.T) {
	p := writeJSONL(t,
		entry("2026-08-06T04:00:00.000Z"),
		entry("2026-08-06T05:00:00.000Z"),
		entry("2026-08-06T06:30:00.000Z"),
	)
	got, ok := lastEntryTime(p)
	if !ok {
		t.Fatal("no timestamp found")
	}
	want := time.Date(2026, 8, 6, 6, 30, 0, 0, time.UTC)
	if !got.Equal(want) {
		t.Errorf("got %s, want %s", got, want)
	}
}

// The file's mtime is NOT the answer: anything that touches a transcript moves
// it. Observed live — three unrelated agents reported an identical age because
// something had swept their files together, while their real last entries were
// nearly two days apart.
func TestLastEntryTimeIgnoresFileMtime(t *testing.T) {
	p := writeJSONL(t, entry("2026-08-04T01:00:00.000Z"))
	touched := time.Date(2026, 8, 6, 12, 0, 0, 0, time.UTC)
	if err := os.Chtimes(p, touched, touched); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
	got, ok := lastEntryTime(p)
	if !ok {
		t.Fatal("no timestamp found")
	}
	if got.Equal(touched) {
		t.Fatal("reported the file's mtime — a backup or sync would fake recent activity")
	}
	if want := time.Date(2026, 8, 4, 1, 0, 0, 0, time.UTC); !got.Equal(want) {
		t.Errorf("got %s, want the last entry's own timestamp %s", got, want)
	}
}

// Only the tail is read, so a long conversation stays cheap — but the newest
// entry must still be found when the head is far out of reach.
func TestLastEntryTimeReadsOnlyTheTail(t *testing.T) {
	var lines []string
	filler := strings.Repeat("x", 900)
	for i := range 400 {
		lines = append(lines,
			fmt.Sprintf(`{"type":"assistant","timestamp":"2026-08-01T00:%02d:00.000Z","pad":%q}`, i%60, filler))
	}
	lines = append(lines, entry("2026-08-06T09:15:00.000Z"))
	p := writeJSONL(t, lines...)

	info, _ := os.Stat(p)
	if info.Size() <= lastActivityTailBytes {
		t.Fatalf("fixture is %d bytes; needs to exceed the %d-byte tail to be a real test",
			info.Size(), lastActivityTailBytes)
	}
	got, ok := lastEntryTime(p)
	if !ok {
		t.Fatal("no timestamp found")
	}
	if want := time.Date(2026, 8, 6, 9, 15, 0, 0, time.UTC); !got.Equal(want) {
		t.Errorf("got %s, want %s", got, want)
	}
}

// A transcript mixes shapes. Lines without a usable timestamp are skipped, not
// treated as a failure — the newest DATED entry is still the answer.
func TestLastEntryTimeSkipsUndatedLines(t *testing.T) {
	p := writeJSONL(t,
		entry("2026-08-06T07:00:00.000Z"),
		`{"type":"summary","summary":"no timestamp here"}`,
		`not json at all`,
		``,
	)
	got, ok := lastEntryTime(p)
	if !ok {
		t.Fatal("no timestamp found")
	}
	if want := time.Date(2026, 8, 6, 7, 0, 0, 0, time.UTC); !got.Equal(want) {
		t.Errorf("got %s, want %s", got, want)
	}
}

func TestLastEntryTimeReportsUnknown(t *testing.T) {
	t.Run("no dated entries", func(t *testing.T) {
		if _, ok := lastEntryTime(writeJSONL(t, `{"type":"summary"}`)); ok {
			t.Error("claimed a time for a transcript with none")
		}
	})
	t.Run("missing file", func(t *testing.T) {
		if _, ok := lastEntryTime(filepath.Join(t.TempDir(), "nope.jsonl")); ok {
			t.Error("claimed a time for a file that does not exist")
		}
	})
}

// A kind whose sessions share one store cannot be dated per agent: the store's
// activity is ANY agent's. Reporting that as this one's age would be
// confidently wrong, which is worse than reporting nothing.
func TestLastActivityOnlyAnswersForResolvableKinds(t *testing.T) {
	for _, kind := range []string{"hermes", "opencode", "codex", "", "unknown"} {
		if _, ok := LastActivity(kind, "/tmp", "sess"); ok {
			t.Errorf("kind %q: claimed an age it cannot know", kind)
		}
	}
}
