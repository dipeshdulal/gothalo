package transcript

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const piCwd = "/Users/alex/projects/gothalo"

// piFixtureEntry normalizes the scrubbed pi sample transcript (testdata/pi_sample.jsonl)
// into the flattened entries in file order.
func piFixtureEntries(t *testing.T) []Entry {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "pi_sample.jsonl"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	r := ReaderFor("pi")
	var out []Entry
	for _, line := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		out = append(out, r.Normalize([]byte(line))...)
	}
	return out
}

func TestPiNormalizeKinds(t *testing.T) {
	entries := piFixtureEntries(t)

	counts := map[string]int{}
	for _, e := range entries {
		counts[e.Kind]++
		if e.Role == "" {
			t.Errorf("entry %s has empty role", e.ID)
		}
	}

	// session/model_change/thinking_level_change/custom must all be dropped.
	if counts[KindThinking] != 1 {
		t.Errorf("thinking entries = %d, want 1", counts[KindThinking])
	}
	if counts[KindToolCall] != 3 {
		t.Errorf("tool_call entries = %d, want 3 (bash-ok, edit, bash-fail)", counts[KindToolCall])
	}
	if counts[KindToolResult] != 3 {
		t.Errorf("tool_result entries = %d, want 3", counts[KindToolResult])
	}
	// user prompt + assistant text x2 + second user text = 4 messages.
	if counts[KindMessage] != 4 {
		t.Errorf("message entries = %d, want 4", counts[KindMessage])
	}
	// The pasted image in the second user message survives as an attachment.
	if counts[KindAttachment] != 1 {
		t.Errorf("attachment entries = %d, want 1", counts[KindAttachment])
	}

	// Every entry from the clean fixture must be Parsed=true.
	for _, e := range entries {
		if !e.Parsed {
			t.Errorf("entry %s (%s) Parsed=false, want true", e.ID, e.Kind)
		}
	}
}

func TestPiToolCallBash(t *testing.T) {
	calls, results := byToolID(piFixtureEntries(t))

	call, ok := calls["call_bash_ok|fc_tmp_1"]
	if !ok {
		t.Fatal("missing bash tool_call")
	}
	if call.Tool.Name != "bash" {
		t.Errorf("Name = %q, want bash", call.Tool.Name)
	}
	if call.Tool.Command != "ls internal/server" {
		t.Errorf("Command = %q", call.Tool.Command)
	}

	res, ok := results["call_bash_ok|fc_tmp_1"]
	if !ok {
		t.Fatal("missing bash tool_result")
	}
	if !res.Result.OK {
		t.Errorf("bash result OK = false, want true")
	}
	if !strings.Contains(res.Result.OutputSummary, "server.go") {
		t.Errorf("OutputSummary = %q, want stdout", res.Result.OutputSummary)
	}
}

func TestPiToolCallEditWithDiff(t *testing.T) {
	calls, results := byToolID(piFixtureEntries(t))

	call, ok := calls["call_edit|fc_tmp_2"]
	if !ok {
		t.Fatal("missing edit tool_call")
	}
	if call.Tool.File != "server.go" {
		t.Errorf("File = %q, want basename server.go", call.Tool.File)
	}
	// The tool_call carries a preview diff built from the first old/new pair.
	if !strings.Contains(call.Tool.Diff, "+") || !strings.Contains(call.Tool.Diff, "handleHealthz") {
		t.Errorf("tool_call Diff missing added line:\n%s", call.Tool.Diff)
	}

	// The tool_result carries the authoritative applied diff from details.diff.
	res, ok := results["call_edit|fc_tmp_2"]
	if !ok {
		t.Fatal("missing edit tool_result")
	}
	if !res.Result.OK {
		t.Errorf("edit result OK = false, want true")
	}
	if !strings.HasPrefix(res.Result.Diff, "@@") || !strings.Contains(res.Result.Diff, "+mux.HandleFunc(\"/healthz\"") {
		t.Errorf("result Diff not a unified diff with the added route:\n%s", res.Result.Diff)
	}
}

func TestPiToolCallWriteDiff(t *testing.T) {
	r := piReader{}
	got := r.Normalize([]byte(
		`{"type":"message","id":"w1","parentId":"","timestamp":"2026-08-09T05:42:00.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_write|fc_tmp_9","name":"write","arguments":{"path":"internal/handlers/healthz.go","content":"package handlers\n\nfunc Healthz() string { return \"ok\" }\n"}}]}}`,
	))
	if len(got) != 1 || got[0].Kind != KindToolCall {
		t.Fatalf("got %d entries kind=%q, want 1 tool_call", len(got), got[0].Kind)
	}
	if got[0].Tool.File != "healthz.go" {
		t.Errorf("File = %q, want healthz.go", got[0].Tool.File)
	}
	if !strings.Contains(got[0].Tool.Diff, "+package handlers") {
		t.Errorf("Write Diff should show added lines:\n%s", got[0].Tool.Diff)
	}
}

func TestPiToolResultFail(t *testing.T) {
	_, results := byToolID(piFixtureEntries(t))
	res, ok := results["call_bash_fail|fc_tmp_3"]
	if !ok {
		t.Fatal("missing failing tool_result")
	}
	if res.Result.OK {
		t.Errorf("failing result OK = true, want false (isError)")
	}
	if !strings.Contains(res.Result.OutputSummary, "cannot find package") {
		t.Errorf("OutputSummary = %q, want the error text", res.Result.OutputSummary)
	}
}

func TestPiThinkingAndMessages(t *testing.T) {
	entries := piFixtureEntries(t)

	var gotThinking, gotUserPrompt, gotImage bool
	for _, e := range entries {
		if e.Kind == KindThinking && strings.Contains(e.Text, "health endpoint") {
			gotThinking = true
			if e.Role != RoleAssistant {
				t.Errorf("thinking role = %q, want assistant", e.Role)
			}
		}
		if e.Kind == KindMessage && e.Role == RoleUser && strings.Contains(e.Text, "/healthz endpoint") {
			gotUserPrompt = true
		}
		if e.Kind == KindAttachment && e.Role == RoleUser && e.Text == "[image]" {
			gotImage = true
		}
	}
	if !gotThinking {
		t.Error("thinking entry not found")
	}
	if !gotUserPrompt {
		t.Error("user prompt message not found")
	}
	if !gotImage {
		t.Error("pasted image attachment not found")
	}
}

func TestPiIDsUniqueAndThreaded(t *testing.T) {
	entries := piFixtureEntries(t)
	seen := map[string]bool{}
	var editResultParent string
	for _, e := range entries {
		if e.ID == "" {
			continue
		}
		if seen[e.ID] {
			t.Errorf("duplicate entry id %q", e.ID)
		}
		seen[e.ID] = true
		if e.Result != nil && e.Result.ForID == "call_edit|fc_tmp_2" {
			editResultParent = e.ParentID
		}
	}
	// The assistant turn with thinking+text+toolCall expands into three entries
	// sharing a uuid with distinct #idx suffixes.
	if !seen["a1#0"] || !seen["a1#1"] || !seen["a1#2"] {
		t.Errorf("expected block-indexed ids a1#0..#2, got %v", keys(seen))
	}
	// A toolResult threads to the assistant message that made the call.
	if editResultParent != "a2" {
		t.Errorf("edit result ParentID = %q, want a2", editResultParent)
	}
}

// TestPiUnparseableAndUnknownPassThrough proves the never-drop contract for pi:
// a non-JSON line, an unknown record type, and an unknown message role all yield
// a single Parsed=false entry rather than crashing or being silently dropped.
func TestPiUnparseableAndUnknownPassThrough(t *testing.T) {
	r := ReaderFor("pi")

	bad := r.Normalize([]byte("this is not json {"))
	if len(bad) != 1 || bad[0].Parsed {
		t.Errorf("unparseable line = %+v, want 1 Parsed=false entry", bad)
	}

	unknown := r.Normalize([]byte(`{"type":"brand-new-type","id":"x1"}`))
	if len(unknown) != 1 || unknown[0].Parsed {
		t.Errorf("unknown type = %+v, want 1 Parsed=false entry", unknown)
	}

	unknownRole := r.Normalize([]byte(`{"type":"message","id":"x2","message":{"role":"bizarre","content":[]}}`))
	if len(unknownRole) != 1 || unknownRole[0].Parsed {
		t.Errorf("unknown role = %+v, want 1 Parsed=false entry", unknownRole)
	}
}

// TestPiDroppedMetadata proves session/model_change/thinking_level_change/custom
// records are pure plumbing and vanish from the stream.
func TestPiDroppedMetadata(t *testing.T) {
	r := piReader{}
	lines := []string{
		`{"type":"session","version":3,"id":"019fe4d1","timestamp":"2026-08-09T04:39:45.424Z","cwd":"/Users/x/proj"}`,
		`{"type":"model_change","timestamp":"2026-08-09T05:40:30.000Z","model":"m1","previousModel":"m0"}`,
		`{"type":"thinking_level_change","timestamp":"2026-08-09T05:40:31.000Z","level":75,"previousLevel":50}`,
		`{"type":"custom","customType":"web-search-results","data":{"queries":[{"query":"x"}]}}`,
	}
	for _, line := range lines {
		if got := r.Normalize([]byte(line)); len(got) != 0 {
			t.Errorf("line %q emitted %d entries, want 0", line, len(got))
		}
	}
}

// TestPiEmptyAssistantDropped covers an assistant turn whose content is empty
// (aborted/failed generation): nothing to show, so nothing is emitted.
func TestPiEmptyAssistantDropped(t *testing.T) {
	r := piReader{}
	got := r.Normalize([]byte(`{"type":"message","id":"x","message":{"role":"assistant","content":[]}}`))
	if len(got) != 0 {
		t.Errorf("empty assistant emitted %d entries, want 0", len(got))
	}
}

func TestPiEncodeSessionDir(t *testing.T) {
	// Verified against live directories and pi's getDefaultSessionDirPath.
	cases := []struct{ cwd, want string }{
		{"/Users/alex", "--Users-alex--"},
		{"/Users/alex/projects/gothalo", "--Users-alex-projects-gothalo--"},
		{"/Users/alex/projects/gothalo/app", "--Users-alex-projects-gothalo-app--"},
	}
	for _, c := range cases {
		if got := EncodePiSessionDir(c.cwd); got != c.want {
			t.Errorf("EncodePiSessionDir(%q) = %q, want %q", c.cwd, got, c.want)
		}
	}
}

// TestPiLocate exercises path resolution against a scratch $HOME so the real
// ~/.pi is never touched.
func TestPiLocate(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	rel := filepath.Join(".pi", "agent", "sessions", EncodePiSessionDir(piCwd), "2026-08-09T06-03-37-199Z_019fe51e-9f6f-7d2a-80dd-77fd21f70ce5.jsonl")
	path := filepath.Join(tmp, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	content := `{"type":"session","version":3,"id":"019fe51e","timestamp":"2026-08-09T06:03:37.199Z","cwd":"` + piCwd + `"}` + "\n" +
		`{"type":"message","id":"u1","parentId":"","timestamp":"2026-08-09T06:04:00.000Z","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}` + "\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	// 1. Direct hit: the session id IS the full path.
	got, err := Locate("pi", piCwd, path)
	if err != nil || got != path {
		t.Errorf("Locate(full path) = %q, %v; want %q", got, err, path)
	}

	// 2. A bare uuid globs the sessions root.
	uuid := "019fe51e-9f6f-7d2a-80dd-77fd21f70ce5"
	got, err = Locate("pi", piCwd, uuid)
	if err != nil || got != path {
		t.Errorf("Locate(uuid) = %q, %v; want %q", got, err, path)
	}

	// 3. A named .jsonl path that does not exist yet is ErrNoTranscript (the
	//    opener serves it as a pending source).
	missing := filepath.Join(tmp, "whatever", "still-pending.jsonl")
	if _, err := Locate("pi", piCwd, missing); !errors.Is(err, ErrNoTranscript) {
		t.Errorf("Locate(pending path) error = %v, want ErrNoTranscript", err)
	}

	// 4. An unknown bare uuid is ErrNoTranscript, never a guess.
	if _, err := Locate("pi", piCwd, "019f0000-0000-0000-0000-000000000000"); !errors.Is(err, ErrNoTranscript) {
		t.Errorf("Locate(unknown uuid) error = %v, want ErrNoTranscript", err)
	}

	// 5. Empty session id falls back to the newest session whose cwd matches.
	got, err = Locate("pi", piCwd, "")
	if err != nil || got != path {
		t.Errorf("Locate(empty) = %q, %v; want %q", got, err, path)
	}

	// 6. Empty session id with a mismatched cwd finds nothing.
	if _, err := Locate("pi", "/Users/someone/else", ""); !errors.Is(err, ErrNoTranscript) {
		t.Errorf("Locate(wrong cwd) error = %v, want ErrNoTranscript", err)
	}

	// 7. Unsupported kinds are untouched.
	if _, err := Locate("codex", piCwd, uuid); !errors.Is(err, ErrUnsupportedKind) {
		t.Errorf("Locate(codex) error = %v, want ErrUnsupportedKind", err)
	}
}

// TestPiOpenStreamsAndAges proves the opener serves a resolved file and that
// LastActivity can now date a pi agent from its newest entry.
func TestPiOpenStreamsAndAges(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	dir := filepath.Join(tmp, ".pi", "agent", "sessions", EncodePiSessionDir(piCwd))
	path := filepath.Join(dir, "2026-08-09T06-03-37-199Z_019fe51e-9f6f-7d2a-80dd-77fd21f70ce5.jsonl")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	content := `{"type":"session","version":3,"id":"019fe51e","timestamp":"2026-08-09T06:03:37.199Z","cwd":"` + piCwd + `"}` + "\n" +
		`{"type":"message","id":"u1","parentId":"","timestamp":"2026-08-09T06:04:00.000Z","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}` + "\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	src, err := piOpener{}.Open(piCwd, path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	b, err := src.Backlog(100)
	if err != nil {
		t.Fatalf("Backlog: %v", err)
	}
	if len(b.Entries) != 1 || b.Entries[0].Kind != KindMessage {
		t.Fatalf("Backlog entries = %+v, want 1 user message", b.Entries)
	}
	if b.Entries[0].Text != "hello" {
		t.Errorf("entry text = %q, want hello", b.Entries[0].Text)
	}

	at, ok := LastActivity("pi", piCwd, path)
	if !ok {
		t.Fatal("LastActivity(pi) reported not answerable")
	}
	if want := "2026-08-09T06:04:00.000Z"; at.UTC().Format("2006-01-02T15:04:05.000Z") != want {
		t.Errorf("LastActivity = %v, want %v", at.UTC().Format("2006-01-02T15:04:05.000Z"), want)
	}
}
