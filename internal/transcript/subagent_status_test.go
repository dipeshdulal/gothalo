package transcript

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeParentLines replaces a parent transcript's body with the given lines.
func writeParentLines(t *testing.T, parent string, lines ...string) {
	t.Helper()
	var body []byte
	for _, l := range lines {
		body = append(body, l...)
		body = append(body, '\n')
	}
	if err := os.WriteFile(parent, body, 0o600); err != nil {
		t.Fatal(err)
	}
}

// writeSubagentLines replaces a subagent transcript's body.
func writeSubagentLines(t *testing.T, parent, id string, lines ...string) {
	t.Helper()
	var body []byte
	for _, l := range lines {
		body = append(body, l...)
		body = append(body, '\n')
	}
	p := filepath.Join(subagentDirFor(parent), "agent-"+id+".jsonl")
	if err := os.WriteFile(p, body, 0o600); err != nil {
		t.Fatal(err)
	}
}

const metaFor = `{"agentType":"general-purpose","description":"Survey the plugin API","toolUseId":"toolu_x","spawnDepth":1}`

// An async agent's Task call gets its tool_result within seconds ("launched
// successfully") while the child runs on for minutes. Completion is reported to
// the parent later, as a task-notification keyed by the AGENT id — which is why
// the result of the spawning call cannot decide this.
func TestSubagentDoneFromCompletionNotification(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "adone", metaFor, true)
	writeSubagent(t, parent, "alive", metaFor, true)

	writeParentLines(t, parent,
		`{"type":"user","message":{"role":"user","content":"<task-notification><task-id>adone</task-id><status>completed</status></task-notification>"}}`,
	)

	got := subagentsBeside(parent)
	byID := map[string]Subagent{}
	for _, s := range got {
		byID[s.AgentID] = s
	}

	if !byID["adone"].Done {
		t.Error("a subagent with a completion notification should be Done")
	}
	if byID["alive"].Done {
		t.Error("a subagent with no completion notification should not be Done")
	}
}

// A failed or cancelled agent has also stopped — anything but a still-running
// status ends it, or the row claims it is working forever.
func TestSubagentDoneOnAnyTerminalStatus(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "afail", metaFor, true)

	writeParentLines(t, parent,
		`{"type":"user","message":{"role":"user","content":"<task-notification><task-id>afail</task-id><status>failed</status></task-notification>"}}`,
	)

	if !subagentsBeside(parent)[0].Done {
		t.Error("a failed agent should be Done")
	}
}

// A notification naming some other task must not end an unrelated subagent —
// background bash tasks report through the same channel with their own ids.
func TestSubagentIgnoresUnrelatedNotification(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "alive", metaFor, true)

	writeParentLines(t, parent,
		`{"type":"queue-operation","content":"<task-notification><task-id>betp8e74l</task-id><status>completed</status></task-notification>"}`,
	)

	if subagentsBeside(parent)[0].Done {
		t.Error("a bash task's notification must not end a subagent")
	}
}

func TestSubagentLastActivityFromNewestEntry(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "alive", metaFor, true)
	writeSubagentLines(t, parent, "alive",
		`{"type":"assistant","timestamp":"2026-09-05T09:00:00.000Z"}`,
		`{"type":"assistant","timestamp":"2026-09-05T09:42:36.000Z"}`,
	)

	got := subagentsBeside(parent)[0]
	want := time.Date(2026, 9, 5, 9, 42, 36, 0, time.UTC)
	if !got.LastActivity.Equal(want) {
		t.Errorf("LastActivity = %v, want %v", got.LastActivity, want)
	}
}

// Absent means unknown, never "just now" — the same rule the agent rows follow.
func TestSubagentLastActivityAbsentWhenUndatable(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "alive", metaFor, true)
	writeSubagentLines(t, parent, "alive", `{"type":"assistant"}`)

	if !subagentsBeside(parent)[0].LastActivity.IsZero() {
		t.Error("an undatable subagent must report no time at all")
	}
}

// The wire carries unix millis, matching `last_activity_ts` on agents, so the
// app renders a subagent's age with the code it already has.
func TestSubagentMarshalsLastActivityAsMillis(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "alive", metaFor, true)
	writeSubagentLines(t, parent, "alive",
		`{"type":"assistant","timestamp":"2026-09-05T09:42:36.000Z"}`,
	)

	raw, err := json.Marshal(subagentsBeside(parent)[0])
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	want := float64(time.Date(2026, 9, 5, 9, 42, 36, 0, time.UTC).UnixMilli())
	if got["last_activity_ts"] != want {
		t.Errorf("last_activity_ts = %v, want %v", got["last_activity_ts"], want)
	}
}

// Absent, not zero — a client must render nothing rather than 1970.
func TestSubagentOmitsUndatableLastActivity(t *testing.T) {
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "alive", metaFor, true)
	writeSubagentLines(t, parent, "alive", `{"type":"assistant"}`)

	raw, err := json.Marshal(subagentsBeside(parent)[0])
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if _, present := got["last_activity_ts"]; present {
		t.Error("an undatable subagent must omit the field entirely")
	}
}
