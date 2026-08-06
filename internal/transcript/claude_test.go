package transcript

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// normalizeFixture reads the scrubbed sample transcript and normalizes every line
// through the claude reader, returning the flattened entries in file order. The
// fixture is synthetic/scrubbed (no real secrets) but structurally identical to a
// live Claude Code JSONL — see testdata/claude_sample.jsonl.
func normalizeFixture(t *testing.T) []Entry {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "claude_sample.jsonl"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	r := ReaderFor("claude")
	var out []Entry
	for _, line := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		out = append(out, r.Normalize([]byte(line))...)
	}
	return out
}

// byToolID indexes tool_call and tool_result entries by their correlation id.
func byToolID(entries []Entry) (calls map[string]Entry, results map[string]Entry) {
	calls, results = map[string]Entry{}, map[string]Entry{}
	for _, e := range entries {
		switch {
		case e.Kind == KindToolCall && e.Tool != nil:
			calls[e.Tool.ID] = e
		case e.Kind == KindToolResult && e.Result != nil:
			results[e.Result.ForID] = e
		}
	}
	return calls, results
}

func TestClaudeNormalizeKinds(t *testing.T) {
	entries := normalizeFixture(t)

	counts := map[string]int{}
	for _, e := range entries {
		counts[e.Kind]++
		if e.Role == "" {
			t.Errorf("entry %s has empty role", e.ID)
		}
	}

	// Metadata (ai-title), the wrapper-only system line, and the deferred_tools
	// attachment must all be dropped; the real system line survives.
	if counts[KindThinking] != 1 {
		t.Errorf("thinking entries = %d, want 1", counts[KindThinking])
	}
	if counts[KindToolCall] != 4 {
		t.Errorf("tool_call entries = %d, want 4 (bash-ok, edit, write, bash-fail)", counts[KindToolCall])
	}
	if counts[KindToolResult] != 4 {
		t.Errorf("tool_result entries = %d, want 4", counts[KindToolResult])
	}
	// user prompt + 2 assistant text + 1 real system line = 4 messages.
	if counts[KindMessage] != 4 {
		t.Errorf("message entries = %d, want 4", counts[KindMessage])
	}
	if counts[KindAttachment] != 0 {
		t.Errorf("attachment entries = %d, want 0 (only noise attachment present)", counts[KindAttachment])
	}

	// Every entry from the (clean) fixture must be Parsed=true.
	for _, e := range entries {
		if !e.Parsed {
			t.Errorf("entry %s (%s) Parsed=false, want true", e.ID, e.Kind)
		}
	}
}

func TestClaudeToolCallBash(t *testing.T) {
	calls, results := byToolID(normalizeFixture(t))

	call, ok := calls["toolu_bash_ok"]
	if !ok {
		t.Fatal("missing bash tool_call")
	}
	if call.Tool.Name != "Bash" {
		t.Errorf("Name = %q, want Bash", call.Tool.Name)
	}
	if call.Tool.Command != "ls internal/server" {
		t.Errorf("Command = %q", call.Tool.Command)
	}
	if !strings.Contains(call.Tool.Subtitle, "List server") {
		t.Errorf("Subtitle = %q, want the description", call.Tool.Subtitle)
	}

	res, ok := results["toolu_bash_ok"]
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

func TestClaudeToolCallEditWithDiff(t *testing.T) {
	calls, results := byToolID(normalizeFixture(t))

	call := calls["toolu_edit"]
	if call.Tool == nil || call.Tool.Name != "Edit" {
		t.Fatalf("missing edit tool_call: %+v", call)
	}
	if call.Tool.File != "server.go" {
		t.Errorf("File = %q, want basename server.go", call.Tool.File)
	}
	// The tool_call carries a preview diff built from old/new strings.
	if !strings.Contains(call.Tool.Diff, "+") || !strings.Contains(call.Tool.Diff, "handleHealthz") {
		t.Errorf("tool_call Diff missing added line:\n%s", call.Tool.Diff)
	}

	// The tool_result carries the authoritative applied diff from structuredPatch.
	res := results["toolu_edit"]
	if res.Result == nil {
		t.Fatal("missing edit tool_result")
	}
	if !res.Result.OK {
		t.Errorf("edit result OK = false, want true")
	}
	if !strings.HasPrefix(res.Result.Diff, "@@") || !strings.Contains(res.Result.Diff, "+\tmux.HandleFunc(\"/healthz\"") {
		t.Errorf("result Diff not a unified diff with the added route:\n%s", res.Result.Diff)
	}
}

func TestClaudeToolWriteDiff(t *testing.T) {
	calls, _ := byToolID(normalizeFixture(t))
	call := calls["toolu_write"]
	if call.Tool == nil || call.Tool.Name != "Write" {
		t.Fatalf("missing write tool_call: %+v", call)
	}
	if !strings.Contains(call.Tool.Diff, "+package server") {
		t.Errorf("Write Diff should show added lines:\n%s", call.Tool.Diff)
	}
}

func TestClaudeToolResultFail(t *testing.T) {
	_, results := byToolID(normalizeFixture(t))
	res := results["toolu_bash_fail"]
	if res.Result == nil {
		t.Fatal("missing failing tool_result")
	}
	if res.Result.OK {
		t.Errorf("failing result OK = true, want false")
	}
	if !strings.Contains(res.Result.OutputSummary, "cannot find package") {
		t.Errorf("OutputSummary = %q, want the stderr", res.Result.OutputSummary)
	}
}

func TestClaudeThinkingAndMessages(t *testing.T) {
	entries := normalizeFixture(t)

	var gotThinking, gotUserPrompt, gotSystem bool
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
		if e.Kind == KindMessage && e.Role == RoleSystem && strings.Contains(e.Text, "auto-compact") {
			gotSystem = true
		}
	}
	if !gotThinking {
		t.Error("thinking entry not found")
	}
	if !gotUserPrompt {
		t.Error("user prompt message not found")
	}
	if !gotSystem {
		t.Error("real system message not found (wrapper-only one should drop, this one shouldn't)")
	}
}

func TestClaudeIDsUniqueAndThreaded(t *testing.T) {
	entries := normalizeFixture(t)
	seen := map[string]bool{}
	for _, e := range entries {
		if e.ID == "" {
			continue
		}
		if seen[e.ID] {
			t.Errorf("duplicate entry id %q", e.ID)
		}
		seen[e.ID] = true
	}
	// The assistant turn with thinking+text expands into two entries sharing a uuid
	// but with distinct #idx suffixes.
	if !seen["a1#0"] || !seen["a1#1"] {
		t.Errorf("expected block-indexed ids a1#0 and a1#1, got %v", keys(seen))
	}
}

// TestUnparseableAndUnknownPassThrough proves the never-drop contract: a non-JSON
// line and an unknown entry type both yield a single Parsed=false entry rather than
// crashing or being silently dropped.
func TestUnparseableAndUnknownPassThrough(t *testing.T) {
	r := ReaderFor("claude")

	bad := r.Normalize([]byte("this is not json {"))
	if len(bad) != 1 || bad[0].Parsed {
		t.Errorf("unparseable line = %+v, want 1 Parsed=false entry", bad)
	}

	unknown := r.Normalize([]byte(`{"type":"brand-new-type","uuid":"x1","message":{"role":"assistant","content":[]}}`))
	if len(unknown) != 1 || unknown[0].Parsed {
		t.Errorf("unknown type = %+v, want 1 Parsed=false entry", unknown)
	}
	if unknown[0].Role != RoleAssistant {
		t.Errorf("unknown type role = %q, want assistant (from message.role)", unknown[0].Role)
	}
}

// TestClaudeImageBlock covers the one attachment path that survives: a pasted
// image arrives as an `image` content block in a user message (top-level
// attachment lines are dropped as plumbing).
func TestClaudeImageBlock(t *testing.T) {
	r := ReaderFor("claude")
	got := r.Normalize([]byte(`{"type":"user","uuid":"img1","message":{"role":"user","content":[{"type":"image","source":{"type":"base64"}}]}}`))
	if len(got) != 1 {
		t.Fatalf("got %d entries, want 1", len(got))
	}
	if got[0].Kind != KindAttachment || got[0].Text != "[image]" || got[0].Role != RoleUser {
		t.Errorf("image entry = %+v, want user attachment [image]", got[0])
	}
}

func keys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// TestClaudeQueuedMessage covers a message typed while Claude was mid-turn.
//
// Claude queues such a message instead of starting a turn, and journals it as
// `queue-operation` lines rather than conversation. Dropping those lost the
// message entirely: it reached the agent but never appeared in the chat, and the
// app's optimistic bubble — which clears only when a matching user entry arrives
// — was stranded forever.
//
// The verb decides. Measured over 222 queued messages in a live corpus:
// enqueue+remove never produces a user entry (158/158), enqueue alone does
// (58/61). So `remove` is the signal, and emitting on `enqueue` instead would
// double-render about a quarter of them.
func TestClaudeQueuedMessage(t *testing.T) {
	r := claudeReader{}

	// enqueue: stay silent — Claude will record this one as a real user entry.
	if got := r.Normalize([]byte(
		`{"type":"queue-operation","operation":"enqueue","content":"hello there","timestamp":"2026-08-04T02:04:52.980Z"}`,
	)); len(got) != 0 {
		t.Errorf("enqueue emitted %d entries, want 0 (the real user entry is still coming)", len(got))
	}

	// remove: emit — this message will never be recorded as conversation.
	got := r.Normalize([]byte(
		`{"type":"queue-operation","operation":"remove","content":"hello there","timestamp":"2026-08-04T02:04:55.694Z"}`,
	))
	if len(got) != 1 {
		t.Fatalf("remove emitted %d entries, want 1", len(got))
	}
	if got[0].Role != RoleUser || got[0].Kind != KindMessage {
		t.Errorf("got role=%q kind=%q, want user/message", got[0].Role, got[0].Kind)
	}
	if got[0].Text != "hello there" {
		t.Errorf("Text = %q, want the queued text", got[0].Text)
	}
	if !got[0].Parsed {
		t.Error("Parsed = false, want true")
	}

	// Bookkeeping verbs carry no message and must stay silent.
	for _, op := range []string{"dequeue", "popAll"} {
		if g := r.Normalize([]byte(
			`{"type":"queue-operation","operation":"` + op + `"}`,
		)); len(g) != 0 {
			t.Errorf("%s emitted %d entries, want 0", op, len(g))
		}
	}

	// A remove with no readable text is dropped rather than rendered blank.
	if g := r.Normalize([]byte(
		`{"type":"queue-operation","operation":"remove","content":"   "}`,
	)); len(g) != 0 {
		t.Errorf("empty remove emitted %d entries, want 0", len(g))
	}
}
