package transcript

import (
	"path/filepath"
	"testing"
)

// sampleTotal is how many normalized entries testdata/claude_sample.jsonl yields.
// The pagination tests assert absolute seq values, so this anchors them.
const sampleTotal = 13

func samplePath() string { return filepath.Join("testdata", "claude_sample.jsonl") }

// The newest page stamps ABSOLUTE seq (position in the whole file), not a
// window-relative 1..N, so a capped page still exposes a real cursor.
func TestReadBacklogStampsAbsoluteSeq(t *testing.T) {
	r := ReaderFor("claude")

	// Full read: seq runs 1..total, oldest cursor is 1, nothing older.
	full, _, err := ReadBacklog(samplePath(), r, 100000)
	if err != nil {
		t.Fatal(err)
	}
	if full.Total != sampleTotal {
		t.Fatalf("Total=%d, want %d", full.Total, sampleTotal)
	}
	if got := full.Entries[0].Seq; got != 1 {
		t.Errorf("first seq=%d, want 1", got)
	}
	if got := full.Entries[len(full.Entries)-1].Seq; got != sampleTotal {
		t.Errorf("last seq=%d, want %d", got, sampleTotal)
	}
	if full.OldestSeq != 1 || full.HasMore {
		t.Errorf("full: OldestSeq=%d HasMore=%v, want 1/false", full.OldestSeq, full.HasMore)
	}

	// Capped newest page: only the last N, but seq is absolute (total-N+1 .. total).
	const cap = 3
	page, _, err := ReadBacklog(samplePath(), r, cap)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Entries) != cap {
		t.Fatalf("len=%d, want %d", len(page.Entries), cap)
	}
	wantOldest := sampleTotal - cap + 1
	if page.OldestSeq != wantOldest {
		t.Errorf("OldestSeq=%d, want %d", page.OldestSeq, wantOldest)
	}
	if page.Entries[0].Seq != wantOldest || page.Entries[cap-1].Seq != sampleTotal {
		t.Errorf("page seq range = [%d..%d], want [%d..%d]",
			page.Entries[0].Seq, page.Entries[cap-1].Seq, wantOldest, sampleTotal)
	}
	if !page.HasMore {
		t.Error("HasMore=false with a capped page")
	}
}

// load_older returns the `limit` entries immediately older than before_seq, in
// oldest→newest order with absolute seq, and reports has_older correctly.
func TestReadOlderSlice(t *testing.T) {
	r := ReaderFor("claude")

	// Newest page was the last 3 (seq 11..13); page older from before_seq=11.
	const before = 11

	// A limit that doesn't reach the head: exactly `limit` entries, older remain.
	got, err := ReadOlder(samplePath(), r, before, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Entries) != 5 {
		t.Fatalf("len=%d, want 5", len(got.Entries))
	}
	if got.Entries[0].Seq != before-5 || got.Entries[4].Seq != before-1 {
		t.Errorf("seq range=[%d..%d], want [%d..%d]",
			got.Entries[0].Seq, got.Entries[4].Seq, before-5, before-1)
	}
	if got.OldestSeq != before-5 || !got.HasOlder {
		t.Errorf("OldestSeq=%d HasOlder=%v, want %d/true", got.OldestSeq, got.HasOlder, before-5)
	}
	// Emitted oldest→newest (strictly increasing seq).
	for i := 1; i < len(got.Entries); i++ {
		if got.Entries[i].Seq <= got.Entries[i-1].Seq {
			t.Fatalf("entries not oldest→newest at %d: %d then %d", i, got.Entries[i-1].Seq, got.Entries[i].Seq)
		}
	}

	// A limit that overshoots the head: entries 1..before-1, nothing older left.
	all, err := ReadOlder(samplePath(), r, before, 500)
	if err != nil {
		t.Fatal(err)
	}
	if len(all.Entries) != before-1 {
		t.Fatalf("len=%d, want %d", len(all.Entries), before-1)
	}
	if all.Entries[0].Seq != 1 || all.OldestSeq != 1 {
		t.Errorf("first seq=%d OldestSeq=%d, want 1/1", all.Entries[0].Seq, all.OldestSeq)
	}
	if all.HasOlder {
		t.Error("HasOlder=true when the page reaches seq 1")
	}
}

// A cursor at the very start of the file returns an empty page with has_older
// false — the app's signal to stop scrolling up.
func TestReadOlderAtStart(t *testing.T) {
	r := ReaderFor("claude")
	for _, before := range []int{1, 0, -3} {
		got, err := ReadOlder(samplePath(), r, before, 150)
		if err != nil {
			t.Fatalf("before=%d: %v", before, err)
		}
		if len(got.Entries) != 0 || got.HasOlder || got.OldestSeq != 0 {
			t.Errorf("before=%d: got %d entries OldestSeq=%d HasOlder=%v, want empty/0/false",
				before, len(got.Entries), got.OldestSeq, got.HasOlder)
		}
	}

	// before_seq=2 loads exactly seq 1, then nothing older.
	got, err := ReadOlder(samplePath(), r, 2, 150)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Entries) != 1 || got.Entries[0].Seq != 1 || got.HasOlder {
		t.Errorf("before=2: got %+v HasOlder=%v, want single seq-1 entry, no older", got.Entries, got.HasOlder)
	}
}
