package herdr

import (
	"encoding/json"
	"testing"
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
