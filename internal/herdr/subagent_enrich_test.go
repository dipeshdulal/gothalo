package herdr

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/transcript"
)

func agentsNode(t *testing.T, raw string) any {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(raw), &v); err != nil {
		t.Fatal(err)
	}
	return v
}

// A session that delegated nothing must carry no field at all, so a row shows
// no badge rather than "0 running" — the same rule last_activity_ts follows.
func TestEnrichAgentSubagentsOmitsWhenNoneDelegated(t *testing.T) {
	node := agentsNode(t, `[{"agent":"claude","cwd":"/nowhere/at/all"}]`)
	enrichAgentSubagents(node)

	obj := node.([]any)[0].(map[string]any)
	if _, present := obj["subagents"]; present {
		t.Errorf("stamped a subagents field on a session with none: %v", obj)
	}
}

// A kind with no per-session transcript cannot be counted; it must be left
// alone rather than reported as zero.
func TestEnrichAgentSubagentsSkipsUncountableKinds(t *testing.T) {
	node := agentsNode(t, `[{"agent":"hermes","cwd":"/x"}]`)
	enrichAgentSubagents(node)

	obj := node.([]any)[0].(map[string]any)
	if _, present := obj["subagents"]; present {
		t.Errorf("counted a kind with a shared store: %v", obj)
	}
}

func TestEnrichAgentSubagentsToleratesJunk(t *testing.T) {
	enrichAgentSubagents(nil)
	enrichAgentSubagents(agentsNode(t, `["not an object", 7, null]`))
}

// The one test that fails if the enrichment is deleted: it must actually stamp
// the counts for a session that has subagents on disk.
func TestEnrichAgentSubagentsStampsTheCounts(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cwd := "/work/proj"
	dir := filepath.Join(home, ".claude", "projects", transcript.EncodeProjectDir(cwd))
	subs := filepath.Join(dir, "sess", "subagents")
	if err := os.MkdirAll(subs, 0o755); err != nil {
		t.Fatal(err)
	}
	parent := filepath.Join(dir, "sess.jsonl")
	if err := os.WriteFile(parent, []byte(
		`{"c":"<task-notification><task-id>adone</task-id><status>completed</status></task-notification>"}`+"\n",
	), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"adone", "alive"} {
		for _, f := range []string{"agent-" + id + ".jsonl", "agent-" + id + ".meta.json"} {
			if err := os.WriteFile(filepath.Join(subs, f), []byte("{}\n"), 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}

	node := agentsNode(t, `[{"agent":"claude","cwd":"`+cwd+`",`+
		`"agent_session":{"value":"sess"}}]`)
	enrichAgentSubagents(node)

	got, ok := node.([]any)[0].(map[string]any)["subagents"].(map[string]any)
	if !ok {
		t.Fatalf("no subagents field stamped: %v", node)
	}
	if got["total"] != 2 || got["running"] != 1 {
		t.Errorf("subagents = %v, want {total:2 running:1}", got)
	}
}
