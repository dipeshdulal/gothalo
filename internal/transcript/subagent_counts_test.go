package transcript

import (
	"fmt"
	"os"
	"testing"
)

func TestSubagentCountsSplitsRunningFromDone(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "adone", metaFor, true)
	writeSubagent(t, parent, "alive", metaFor, true)
	writeSubagent(t, parent, "alive2", metaFor, true)
	writeParentLines(t, parent,
		`{"type":"user","content":"<task-notification><task-id>adone</task-id><status>completed</status></task-notification>"}`,
	)

	got := countsBeside(parent)
	if got.Total != 3 || got.Running != 2 {
		t.Errorf("counts = %+v, want {Total:3 Running:2}", got)
	}
}

// A session that never delegated must report nothing, so the row shows no
// badge rather than "0 running".
func TestSubagentCountsZeroWhenNoneDelegated(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")

	if got := countsBeside(parent); got.Total != 0 || got.Running != 0 {
		t.Errorf("counts = %+v, want zero", got)
	}
}

// The snapshot is polled constantly and these parents reach 1.4 MB, so a
// completion scan must not re-read the whole file every tick. Transcripts are
// append-only, so only the bytes added since the last scan are read.
func TestCompletedAgentsRereadsOnlyWhatWasAppended(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeParentLines(t, parent,
		`{"c":"<task-notification><task-id>a1</task-id><status>completed</status></task-notification>"}`,
	)

	first := completedAgents(parent)
	if !first["a1"] {
		t.Fatalf("first scan missed a1: %v", first)
	}
	firstBytes := scanStats(parent)

	f, err := os.OpenFile(parent, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.WriteString(
		`{"c":"<task-notification><task-id>a2</task-id><status>completed</status></task-notification>"}` + "\n")
	_ = f.Close()

	second := completedAgents(parent)
	if !second["a1"] || !second["a2"] {
		t.Errorf("second scan lost a completion: %v", second)
	}
	if grew := scanStats(parent) - firstBytes; grew > 200 {
		t.Errorf("re-read %d bytes for a ~100 byte append; the scan is not incremental", grew)
	}
}

// A truncated or replaced transcript is not an append — the cursor has to go
// back to the start, or every completion before the rewrite is lost.
func TestCompletedAgentsRescansWhenFileShrinks(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeParentLines(t, parent,
		`{"c":"<task-notification><task-id>a1</task-id><status>completed</status></task-notification>"}`,
		`{"c":"padding padding padding padding padding padding padding padding"}`,
	)
	_ = completedAgents(parent)

	writeParentLines(t, parent,
		`{"c":"<task-notification><task-id>a9</task-id><status>completed</status></task-notification>"}`,
	)

	got := completedAgents(parent)
	if !got["a9"] {
		t.Errorf("a rewritten transcript was not rescanned: %v", got)
	}
}

// A write caught mid-line must not leave the cursor inside it, or the
// notification split across the two scans is never matched by either.
func TestCompletedAgentsSurvivesAPartialLine(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	if err := os.WriteFile(parent,
		[]byte(`{"c":"<task-notification><task-id>a1</task-id><stat`), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := completedAgents(parent); len(got) != 0 {
		t.Fatalf("matched a half-written notification: %v", got)
	}

	f, _ := os.OpenFile(parent, os.O_APPEND|os.O_WRONLY, 0o600)
	_, _ = f.WriteString(`us>completed</status></task-notification>"}` + "\n")
	_ = f.Close()

	if got := completedAgents(parent); !got["a1"] {
		t.Errorf("completion lost across the line boundary: %v", got)
	}
}

// The bridge runs for weeks and every session rotation is a new parent path,
// so the scan cache must not grow without bound.
func TestScanCacheIsBounded(t *testing.T) {
	resetScanCache()
	root := t.TempDir()
	for i := 0; i < scanCacheMax+40; i++ {
		p := writeSession(t, root, "/x/proj", fmt.Sprintf("sess-%d", i))
		writeParentLines(t, p, `{"c":"noise"}`)
		_ = completedAgents(p)
	}

	scanMu.Lock()
	n := len(scanCache)
	scanMu.Unlock()

	if n > scanCacheMax {
		t.Errorf("scan cache holds %d entries, cap is %d", n, scanCacheMax)
	}
}

// Opening one child must not pay for the roster's enrichment. Discovery there
// exists only to turn an id into a path safely; dating every sibling and
// scanning a 10 MB parent to do it is the difference between a cheap connect
// and megabytes of reads per stream.
func TestOpenSubagentDoesNotScanTheParent(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "a1", metaFor, true)
	resetScanCache()

	if _, err := openSubagentBeside(parent, "claude", "a1"); err != nil {
		t.Fatal(err)
	}

	if n := scanStats(parent); n != 0 {
		t.Errorf("opening one child read %d bytes of the parent; want 0", n)
	}
}

// …and an unknown id is still refused, so the cheap path keeps the property
// that a client id can never become a path.
func TestOpenSubagentStillRefusesAnUnknownID(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "a1", metaFor, true)

	if _, err := openSubagentBeside(parent, "claude", "../../etc/passwd"); err == nil {
		t.Error("an id that is not in the listing was accepted")
	}
}
