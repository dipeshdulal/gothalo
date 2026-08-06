package herdr

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
)

func TestQualifyAndSplitTarget(t *testing.T) {
	cases := []struct {
		session, id, qualified string
	}{
		{"", "w1:p2", "w1:p2"},
		{"default", "w1:p2", "w1:p2"},
		{"acme", "w1:p2", "acme/w1:p2"},
		{"acme", "", ""},
	}
	for _, c := range cases {
		if got := Qualify(c.session, c.id); got != c.qualified {
			t.Errorf("Qualify(%q,%q) = %q, want %q", c.session, c.id, got, c.qualified)
		}
	}

	splits := []struct {
		target, session, id string
	}{
		{"w1:p2", "", "w1:p2"},
		{"acme/w1:p2", "acme", "w1:p2"},
		{"default/w1:p2", "", "w1:p2"},
	}
	for _, c := range splits {
		s, id := SplitTarget(c.target)
		if s != c.session || id != c.id {
			t.Errorf("SplitTarget(%q) = (%q,%q), want (%q,%q)", c.target, s, id, c.session, c.id)
		}
	}
}

func TestQualifyIDsWalksNestedPayloads(t *testing.T) {
	raw := `{
		"focused_pane_id": "w1:p1",
		"agents": [{"pane_id":"w1:p1","workspace_id":"w1","cwd":"/tmp/x"}],
		"layouts": [{"panes":[{"pane_id":"w1:p2"}],"area":{"x":1}}]
	}`
	var v any
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		t.Fatal(err)
	}
	QualifyIDs(v, "acme")
	m := v.(map[string]any)
	if m["focused_pane_id"] != "acme/w1:p1" {
		t.Errorf("focused_pane_id = %v", m["focused_pane_id"])
	}
	agent := m["agents"].([]any)[0].(map[string]any)
	if agent["pane_id"] != "acme/w1:p1" || agent["workspace_id"] != "acme/w1" {
		t.Errorf("agent ids not qualified: %v", agent)
	}
	if agent["cwd"] != "/tmp/x" {
		t.Errorf("non-id field rewritten: %v", agent["cwd"])
	}
	layoutPane := m["layouts"].([]any)[0].(map[string]any)["panes"].([]any)[0].(map[string]any)
	if layoutPane["pane_id"] != "acme/w1:p2" {
		t.Errorf("nested layout pane not qualified: %v", layoutPane)
	}
}

func TestQualifyIDsDefaultSessionIsNoop(t *testing.T) {
	var v any
	_ = json.Unmarshal([]byte(`{"pane_id":"w1:p1"}`), &v)
	QualifyIDs(v, "")
	if !reflect.DeepEqual(v, map[string]any{"pane_id": "w1:p1"}) {
		t.Errorf("default session must not rewrite ids: %v", v)
	}
}

func TestManagerClientResolution(t *testing.T) {
	m := NewManager(nil)

	for _, name := range []string{"", "default"} {
		c, err := m.Client(name)
		if err != nil || c.Session() != "" {
			t.Errorf("Client(%q) = (%v, %v), want default client", name, c, err)
		}
	}

	if _, err := m.Client("nope"); err == nil || !IsNotFound(err) {
		t.Errorf("unknown session error should satisfy IsNotFound, got %v", err)
	}
}

func TestEnrichAgentBranches(t *testing.T) {
	// A real repo on branch "feat/x"...
	repo := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = repo
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	git("init", "-q", "-b", "feat/x")
	git("config", "user.email", "t@e.com")
	git("config", "user.name", "T")
	if err := os.WriteFile(filepath.Join(repo, "f.txt"), []byte("hi\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git("add", ".")
	git("commit", "-q", "-m", "base")

	// ...and a plain non-repo dir.
	nonRepo := t.TempDir()

	agents := []any{
		// foreground_cwd (the repo) is preferred over the launch cwd (non-repo).
		map[string]any{"pane_id": "w1:p1", "cwd": nonRepo, "foreground_cwd": repo},
		// Same repo cwd → deduped, still resolved.
		map[string]any{"pane_id": "w1:p2", "cwd": repo},
		// A non-repo dir → empty branch, never absent.
		map[string]any{"pane_id": "w2:p1", "cwd": nonRepo},
	}

	enrichAgentBranches(agents)

	want := map[string]string{"w1:p1": "feat/x", "w1:p2": "feat/x", "w2:p1": ""}
	for _, it := range agents {
		obj := it.(map[string]any)
		id := obj["pane_id"].(string)
		br, ok := obj["branch"]
		if !ok {
			t.Errorf("%s: branch field missing; it must always be set", id)
			continue
		}
		if br != want[id] {
			t.Errorf("%s: branch = %q, want %q", id, br, want[id])
		}
	}
}

// attention_rank is what the app sorts the inbox on, so it must be present on
// every agent and must never let an unrecognised status outrank a real one.
func TestEnrichAgentAttention(t *testing.T) {
	agents := []any{
		map[string]any{"pane_id": "w1:p1", "agent_status": "idle"},
		map[string]any{"pane_id": "w1:p2", "agent_status": "blocked"},
		map[string]any{"pane_id": "w2:p1", "agent_status": "working"},
		map[string]any{"pane_id": "w2:p2", "agent_status": "done"},
		map[string]any{"pane_id": "w3:p1", "agent_status": "unknown"},
		// A status Herdr might add later must degrade to "sorts last", not to 0.
		map[string]any{"pane_id": "w3:p2", "agent_status": "hibernating"},
		// A malformed/absent status must still get a field to sort on.
		map[string]any{"pane_id": "w3:p3"},
	}

	enrichAgentAttention(agents)

	want := map[string]int{
		"w1:p1": 3, "w1:p2": 0, "w2:p1": 2, "w2:p2": 1,
		"w3:p1": 4, "w3:p2": 4, "w3:p3": 4,
	}
	for _, it := range agents {
		obj := it.(map[string]any)
		id := obj["pane_id"].(string)
		got, ok := obj["attention_rank"]
		if !ok {
			t.Errorf("%s: attention_rank missing; it must always be set", id)
			continue
		}
		if got != want[id] {
			t.Errorf("%s: attention_rank = %v, want %d", id, got, want[id])
		}
	}
}

// The enrichers run over whatever the merge produced, which may be absent or a
// non-array when every session failed to report agents.
func TestEnrichAgentAttentionToleratesMissingAgents(t *testing.T) {
	enrichAgentAttention(nil)
	enrichAgentAttention([]any{})
	enrichAgentAttention("not-an-array")
	enrichAgentAttention([]any{"not-an-object", 42})
}
