package transcript

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// writeSession lays out a parent transcript plus an optional subagents dir in a
// temp tree, mirroring the real on-disk shape:
//
//	<root>/<encoded-cwd>/<session>.jsonl
//	<root>/<encoded-cwd>/<session>/subagents/agent-<id>.{jsonl,meta.json}
//
// It returns the parent transcript path.
func writeSession(t *testing.T, root, cwd, session string) string {
	t.Helper()
	dir := filepath.Join(root, EncodeProjectDir(cwd))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	parent := filepath.Join(dir, session+".jsonl")
	if err := os.WriteFile(parent, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return parent
}

// writeSubagent creates agent-<id>.jsonl and, when meta is non-empty, its
// agent-<id>.meta.json. Passing meta == "" exercises the missing-metadata path.
func writeSubagent(t *testing.T, parent, id, meta string, withBody bool) {
	t.Helper()
	dir := subagentDirFor(parent)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if withBody {
		body := filepath.Join(dir, "agent-"+id+".jsonl")
		if err := os.WriteFile(body, []byte("{}\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if meta != "" {
		m := filepath.Join(dir, "agent-"+id+".meta.json")
		if err := os.WriteFile(m, []byte(meta), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestSubagentDirFor(t *testing.T) {
	got := subagentDirFor("/p/-Users-x-proj/abc-123.jsonl")
	want := filepath.Join("/p/-Users-x-proj/abc-123", "subagents")
	if got != want {
		t.Errorf("subagentDirFor = %q, want %q", got, want)
	}
}

func TestAgentIDFromMeta(t *testing.T) {
	tests := []struct {
		name   string
		in     string
		wantID string
		wantOK bool
	}{
		{"valid", "agent-a31269e6c30ff1763.meta.json", "a31269e6c30ff1763", true},
		{"transcript not meta", "agent-a31269e6c30ff1763.jsonl", "", false},
		{"missing prefix", "a31269e6c30ff1763.meta.json", "", false},
		{"empty id", "agent-.meta.json", "", false},
		{"unrelated file", "notes.txt", "", false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			id, ok := agentIDFromMeta(tc.in)
			if id != tc.wantID || ok != tc.wantOK {
				t.Errorf("agentIDFromMeta(%q) = (%q,%v), want (%q,%v)",
					tc.in, id, ok, tc.wantID, tc.wantOK)
			}
		})
	}
}

// The flat-directory property is the one that matters most: a depth-2 grandchild
// sits beside its depth-1 parent rather than nesting, and both must be returned.
func TestSubagentsBesideFlatWithDepth(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/Users/x/proj", "sess-1")

	writeSubagent(t, parent, "bbb", `{"agentType":"general-purpose","description":"build it","toolUseId":"toolu_parent","spawnDepth":1}`, true)
	writeSubagent(t, parent, "aaa", `{"agentType":"Explore","description":"look around","toolUseId":"toolu_child","spawnDepth":2}`, true)

	got := subagentsBeside(parent)
	if len(got) != 2 {
		t.Fatalf("got %d subagents, want 2: %+v", len(got), got)
	}
	// Sorted by depth first, so the depth-1 row leads regardless of id order.
	if got[0].AgentID != "bbb" || got[0].SpawnDepth != 1 {
		t.Errorf("first = %+v, want agent bbb at depth 1", got[0])
	}
	if got[0].ToolUseID != "toolu_parent" || got[0].AgentType != "general-purpose" || got[0].Description != "build it" {
		t.Errorf("metadata not carried through: %+v", got[0])
	}
	if got[1].AgentID != "aaa" || got[1].SpawnDepth != 2 {
		t.Errorf("second = %+v, want agent aaa at depth 2", got[1])
	}
	if got[1].ToolUseID != "toolu_child" {
		t.Errorf("depth-2 ToolUseID = %q, want toolu_child (it joins to a "+
			"tool call inside another subagent, not the session)", got[1].ToolUseID)
	}
}

func TestSubagentsBesideNoDirIsEmptyNotError(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/Users/x/proj", "sess-1")

	got := subagentsBeside(parent)
	if got == nil {
		t.Fatal("got nil, want an empty non-nil slice so callers can range freely")
	}
	if len(got) != 0 {
		t.Errorf("got %d subagents, want 0", len(got))
	}
}

func TestSubagentsBesideSkipsAndTolerates(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/Users/x/proj", "sess-1")

	// Advertised by metadata but with no transcript to open — must be dropped.
	writeSubagent(t, parent, "nobody", `{"spawnDepth":1}`, false)
	// Metadata that is not valid JSON — keep the row, since the transcript is
	// still streamable; it just loses its labels.
	writeSubagent(t, parent, "broken", `{not json`, true)
	// A transcript with no metadata at all is not advertised: discovery keys off
	// the meta file.
	writeSubagent(t, parent, "orphan", "", true)
	// A stray file must not be mistaken for a subagent.
	if err := os.WriteFile(filepath.Join(subagentDirFor(parent), "README.md"), []byte("hi"), 0o600); err != nil {
		t.Fatal(err)
	}

	got := subagentsBeside(parent)
	if len(got) != 1 {
		t.Fatalf("got %d subagents, want only the broken-metadata one: %+v", len(got), got)
	}
	if got[0].AgentID != "broken" {
		t.Errorf("kept %q, want %q", got[0].AgentID, "broken")
	}
	if got[0].AgentType != "" || got[0].ToolUseID != "" {
		t.Errorf("unparsable metadata should leave labels empty, got %+v", got[0])
	}
}

func TestSubagentsAndOpenSubagentEndToEnd(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cwd := "/Users/x/proj"
	root := filepath.Join(home, ".claude", "projects")
	parent := writeSession(t, root, cwd, "sess-1")
	writeSubagent(t, parent, "aaa", `{"agentType":"Explore","toolUseId":"toolu_1","spawnDepth":1}`, true)

	subs, err := Subagents("claude", cwd, "sess-1")
	if err != nil {
		t.Fatalf("Subagents: %v", err)
	}
	if len(subs) != 1 || subs[0].AgentID != "aaa" {
		t.Fatalf("got %+v, want one subagent aaa", subs)
	}

	src, err := OpenSubagent("claude", cwd, "sess-1", "aaa")
	if err != nil {
		t.Fatalf("OpenSubagent: %v", err)
	}
	defer src.Close()
	if _, err := src.Backlog(10); err != nil {
		t.Errorf("Backlog on subagent source: %v", err)
	}
}

// A client-supplied agent id must never reach the filesystem as a path. These
// ids are matched against discovery output, so traversal cannot be expressed —
// assert that directly rather than trusting the implementation to keep filtering.
func TestOpenSubagentRejectsUnknownAndTraversalIDs(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cwd := "/Users/x/proj"
	root := filepath.Join(home, ".claude", "projects")
	parent := writeSession(t, root, cwd, "sess-1")
	writeSubagent(t, parent, "aaa", `{"spawnDepth":1}`, true)

	// A real file the traversal attempts would reach if paths were built from input.
	secret := filepath.Join(home, "secret.jsonl")
	if err := os.WriteFile(secret, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	for _, id := range []string{
		"unknown",
		"../../../secret",
		"../../secret",
		"/etc/passwd",
		"",
	} {
		t.Run("id="+id, func(t *testing.T) {
			src, err := OpenSubagent("claude", cwd, "sess-1", id)
			if !errors.Is(err, ErrNoTranscript) {
				t.Errorf("err = %v, want ErrNoTranscript", err)
			}
			if src != nil {
				src.Close()
				t.Error("got a Source for a non-discovered id")
			}
		})
	}
}

func TestSubagentsPropagatesLocateError(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	// Known session id that was never written: Locate stops at ErrNoTranscript
	// rather than guessing another pane's file, and Subagents must not soften it.
	if _, err := Subagents("claude", "/Users/x/proj", "never-written"); !errors.Is(err, ErrNoTranscript) {
		t.Errorf("err = %v, want ErrNoTranscript", err)
	}
	if _, err := Subagents("codex", "/Users/x/proj", "sess-1"); !errors.Is(err, ErrUnsupportedKind) {
		t.Errorf("codex err = %v, want ErrUnsupportedKind", err)
	}
}
