package timeline

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// base is the wall clock every test measures against, so a duration
// assertion is an exact number rather than a tolerance.
//
// Anchored to the real clock, not a literal date: Open() evicts against
// time.Now, so a hardcoded base silently ages past Retention and every test
// that reloads from disk starts failing three days after it was written.
var base = time.Now().UTC().Truncate(time.Hour)

// at returns base offset by d, as unix millis — the form entries carry.
func at(d time.Duration) int64 { return base.Add(d).UnixMilli() }

// newLog builds a memory-only ring pinned to a fake clock. Memory-only (empty
// path) is the right default here: only the persistence tests care about a file,
// and Flush is a no-op without one.
func newLog(now time.Time) *Log {
	l := &Log{}
	l.now = func() time.Time { return now }
	return l
}

func entry(ts int64, pane, to string) Entry {
	return Entry{TS: ts, Pane: pane, To: to}
}

func TestEntriesNewestFirst(t *testing.T) {
	l := newLog(base)
	l.Append(entry(at(0), "w1:p1", "working"))
	l.Append(entry(at(time.Minute), "w1:p1", "blocked"))
	l.Append(entry(at(2*time.Minute), "w1:p2", "idle"))

	got := l.Entries(0, "")
	if len(got) != 3 {
		t.Fatalf("len = %d, want 3", len(got))
	}
	want := []int64{at(2 * time.Minute), at(time.Minute), at(0)}
	for i, ts := range want {
		if got[i].TS != ts {
			t.Errorf("entry %d ts = %d, want %d", i, got[i].TS, ts)
		}
	}
}

// An entry that arrives with an older timestamp than the one before it (a clock
// that stepped backwards) must not break the newest-first guarantee readers
// depend on.
func TestAppendOutOfOrderIsSorted(t *testing.T) {
	l := newLog(base)
	l.Append(entry(at(time.Minute), "w1:p1", "working"))
	l.Append(entry(at(0), "w1:p1", "idle"))

	got := l.Entries(0, "")
	if got[0].TS != at(time.Minute) || got[1].TS != at(0) {
		t.Fatalf("order = %d,%d; want %d,%d", got[0].TS, got[1].TS, at(time.Minute), at(0))
	}
}

func TestEntriesLimit(t *testing.T) {
	l := newLog(base)
	for i := range DefaultLimit + 20 {
		l.Append(entry(at(time.Duration(i)*time.Second), "w1:p1", "working"))
	}

	cases := []struct {
		name  string
		limit int
		want  int
	}{
		{"explicit", 5, 5},
		{"zero means default", 0, DefaultLimit},
		{"negative means default", -3, DefaultLimit},
		{"above the cap is clamped", MaxLimit + 1000, DefaultLimit + 20},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := len(l.Entries(c.limit, "")); got != c.want {
				t.Errorf("len = %d, want %d", got, c.want)
			}
		})
	}
}

// The cap must bound the RESPONSE, not just the request, or one call could be
// asked to marshal the entire ring.
func TestEntriesClampsToMaxLimit(t *testing.T) {
	l := newLog(base)
	for i := range MaxLimit + 50 {
		l.Append(entry(at(time.Duration(i)*time.Second), "w1:p1", "working"))
	}
	if got := len(l.Entries(MaxLimit+50, "")); got != MaxLimit {
		t.Errorf("len = %d, want %d", got, MaxLimit)
	}
}

func TestEntriesPaneFilter(t *testing.T) {
	l := newLog(base)
	l.Append(entry(at(0), "w1:p1", "working"))
	l.Append(entry(at(time.Minute), "acme/w1:p2", "blocked"))
	l.Append(entry(at(2*time.Minute), "w1:p1", "idle"))

	got := l.Entries(0, "w1:p1")
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
	for _, e := range got {
		if e.Pane != "w1:p1" {
			t.Errorf("pane = %q, want w1:p1", e.Pane)
		}
	}

	// A session-qualified id must match exactly, not by suffix — "w1:p2" and
	// "acme/w1:p2" are different panes on different machines.
	if got := l.Entries(0, "w1:p2"); len(got) != 0 {
		t.Errorf("unqualified filter matched %d entries, want 0", len(got))
	}
	if got := l.Entries(0, "acme/w1:p2"); len(got) != 1 {
		t.Errorf("qualified filter matched %d entries, want 1", len(got))
	}
}

// The body must carry `[]`, never `null`: a client should not have to
// special-case a bridge with no history yet.
func TestEntriesEmptyMarshalsAsArray(t *testing.T) {
	b, err := json.Marshal(newLog(base).Entries(0, ""))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(b) != "[]" {
		t.Errorf("json = %s, want []", b)
	}
}

func TestEvictsOldestOverMaxEntries(t *testing.T) {
	l := newLog(base)
	for i := range MaxEntries + 10 {
		l.Append(entry(at(time.Duration(i)*time.Second), "w1:p1", "working"))
	}
	if l.Len() != MaxEntries {
		t.Fatalf("Len = %d, want %d", l.Len(), MaxEntries)
	}
	// The first 10 are the ones that must be gone.
	oldest := l.Entries(MaxLimit, "")[MaxLimit-1]
	if want := at(time.Duration(MaxEntries+10-MaxLimit) * time.Second); oldest.TS != want {
		t.Errorf("oldest retained ts = %d, want %d", oldest.TS, want)
	}
}

func TestEvictsPastRetention(t *testing.T) {
	l := newLog(base)
	l.Append(entry(at(-Retention-time.Hour), "w1:p1", "working")) // well outside
	l.Append(entry(at(-Retention+time.Hour), "w1:p1", "blocked")) // just inside
	l.Append(entry(at(0), "w1:p1", "idle"))

	if l.Len() != 2 {
		t.Fatalf("Len = %d, want 2 (one entry past retention should be gone)", l.Len())
	}
	for _, e := range l.Entries(0, "") {
		if e.To == "working" {
			t.Error("entry past the retention window survived")
		}
	}
}

// Retention is a promise about what the ring CONTAINS, and eviction is driven by
// the clock, not by appends. A bridge that records nothing for days — exactly
// the state a retention window exists for — must still shed entries as they age
// out, which is why Flush prunes before it checks its dirty flag.
func TestFlushPrunesAQuietRing(t *testing.T) {
	l := newLog(base)
	l.Append(entry(at(0), "w1:p1", "blocked"))
	if err := l.Flush(); err != nil {
		t.Fatalf("Flush: %v", err)
	}

	// Time passes; nothing new is recorded.
	l.now = func() time.Time { return base.Add(Retention + time.Hour) }
	if err := l.Flush(); err != nil {
		t.Fatalf("Flush: %v", err)
	}
	if l.Len() != 0 {
		t.Errorf("Len = %d, want 0 — a quiet ring never shed its stale entries", l.Len())
	}
}

// A bridge restart is precisely when the recent past is most valuable, so the
// entries must come back off disk.
func TestPersistsAcrossRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "timeline.json")
	prevMS := int64(90_000)

	l := Open(path)
	l.now = func() time.Time { return base }
	l.Append(Entry{
		TS: at(0), Pane: "acme/w1:p2", Agent: "claude", Session: "acme",
		Workspace: "acme/w1", From: "working", To: "blocked", PrevMS: &prevMS,
	})
	if err := l.Flush(); err != nil {
		t.Fatalf("Flush: %v", err)
	}

	reopened := Open(path)
	reopened.now = func() time.Time { return base }
	got := reopened.Entries(0, "")
	if len(got) != 1 {
		t.Fatalf("len after reopen = %d, want 1", len(got))
	}
	e := got[0]
	if e.Pane != "acme/w1:p2" || e.Agent != "claude" || e.Session != "acme" ||
		e.Workspace != "acme/w1" || e.From != "working" || e.To != "blocked" {
		t.Errorf("entry did not round-trip: %+v", e)
	}
	if e.PrevMS == nil || *e.PrevMS != prevMS {
		t.Errorf("prev_ms = %v, want %d", e.PrevMS, prevMS)
	}
}

// Loading applies the retention window, so a bridge that was off for a week does
// not come back with a week-old timeline.
func TestOpenDropsEntriesPastRetention(t *testing.T) {
	path := filepath.Join(t.TempDir(), "timeline.json")
	stale := []Entry{
		{TS: at(-Retention - time.Hour), Pane: "w1:p1", To: "working"},
		{TS: at(-time.Hour), Pane: "w1:p1", To: "blocked"},
	}
	b, err := json.Marshal(stale)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}

	l := Open(path)
	l.now = func() time.Time { return base }
	// Open trims against the real clock; re-run the bounds against the fake one.
	l.mu.Lock()
	l.evictLocked()
	l.mu.Unlock()

	if l.Len() != 1 {
		t.Fatalf("Len = %d, want 1", l.Len())
	}
	if got := l.Entries(0, "")[0].To; got != "blocked" {
		t.Errorf("survivor = %q, want blocked", got)
	}
}

// A history file that has gone bad must never stop the bridge starting: pairing,
// approvals and push all depend on it, and the timeline is a convenience.
func TestOpenToleratesBadInput(t *testing.T) {
	dir := t.TempDir()
	cases := []struct {
		name    string
		write   func(path string)
		wantLen int
	}{
		{"missing file", func(string) {}, 0},
		{"corrupt json", func(p string) {
			_ = os.WriteFile(p, []byte("{not json"), 0o600)
		}, 0},
		{"wrong shape", func(p string) {
			_ = os.WriteFile(p, []byte(`{"entries":[]}`), 0o600)
		}, 0},
		{"empty file", func(p string) { _ = os.WriteFile(p, nil, 0o600) }, 0},
	}
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path := filepath.Join(dir, string(rune('a'+i))+".json")
			c.write(path)
			l := Open(path)
			if l.Len() != c.wantLen {
				t.Errorf("Len = %d, want %d", l.Len(), c.wantLen)
			}
			// It must still be usable — a bad file is overwritten, not fatal.
			l.Append(entry(time.Now().UnixMilli(), "w1:p1", "idle"))
			if err := l.Flush(); err != nil {
				t.Errorf("Flush after bad load: %v", err)
			}
		})
	}
}

func TestLatestReturnsNewestForPane(t *testing.T) {
	l := newLog(base)
	l.Append(entry(at(0), "w1:p1", "working"))
	l.Append(entry(at(time.Minute), "w1:p2", "blocked"))
	l.Append(entry(at(2*time.Minute), "w1:p1", "blocked"))

	got, ok := l.Latest("w1:p1")
	if !ok {
		t.Fatal("Latest reported no entry for w1:p1")
	}
	if got.TS != at(2*time.Minute) || got.To != "blocked" {
		t.Errorf("Latest = %+v, want the 2m blocked entry", got)
	}
	if _, ok := l.Latest("w9:p9"); ok {
		t.Error("Latest reported an entry for a pane with no history")
	}
}

// Flush must be a no-op when nothing changed, so it is safe on a tight timer.
func TestFlushIsNoOpWhenClean(t *testing.T) {
	path := filepath.Join(t.TempDir(), "timeline.json")
	l := Open(path)
	l.now = func() time.Time { return base }
	l.Append(entry(at(0), "w1:p1", "working"))
	if err := l.Flush(); err != nil {
		t.Fatalf("Flush: %v", err)
	}
	first, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}

	if err := l.Flush(); err != nil {
		t.Fatalf("second Flush: %v", err)
	}
	second, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if !first.ModTime().Equal(second.ModTime()) {
		t.Error("a clean Flush rewrote the file")
	}
	// And no temp file left behind by the atomic write.
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Error("flush left its temp file behind")
	}
}
