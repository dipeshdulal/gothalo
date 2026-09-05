package transcript

import (
	"fmt"
	"testing"
)

// A synchronous agent never sends a task-notification. It reports by returning,
// so reading notifications alone leaves it running forever — which is what
// shipped: a plain parallel fan-out of 4 children, all 4 returned, the parent
// idle, and the row said "4 running" with the ages climbing.
//
// The rule that makes this safe to read is that the spawning call states which
// kind of agent it is. These pin both directions of that: a synchronous call's
// result ends its agent, and an asynchronous one's does not.

// spawnLine is one assistant line containing a Task/Agent tool call.
func spawnLine(toolUseID, name string, background any) string {
	bg := ""
	if background != nil {
		bg = fmt.Sprintf(`,"run_in_background":%v`, background)
	}
	return fmt.Sprintf(
		`{"type":"assistant","message":{"content":[{"type":"tool_use","id":%q,`+
			`"name":%q,"input":{"description":"do a thing"%s}}]}}`,
		toolUseID, name, bg)
}

// resultLine is the user-side line carrying that call's result.
func resultLine(toolUseID string) string {
	return fmt.Sprintf(
		`{"type":"user","message":{"content":[{"type":"tool_result",`+
			`"tool_use_id":%q,"content":"done"}]}}`, toolUseID)
}

// meta returns an agent-<id>.meta.json body joining an agent to its call.
func meta(toolUseID string) string {
	return fmt.Sprintf(
		`{"agentType":"general-purpose","description":"d","toolUseId":%q,"spawnDepth":1}`,
		toolUseID)
}

func TestSyncAgentIsDoneWhenItsCallReturns(t *testing.T) {
	resetScanCache()
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "a1", meta("toolu_1"), true)
	writeParentLines(t, parent,
		spawnLine("toolu_1", "Agent", false),
		resultLine("toolu_1"),
	)

	if got := countsBeside(parent); got.Total != 1 || got.Running != 0 {
		t.Errorf("a returned synchronous agent still counted as running: %+v", got)
	}
}

func TestSyncAgentStillRunningBeforeItsCallReturns(t *testing.T) {
	resetScanCache()
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "a1", meta("toolu_1"), true)
	writeParentLines(t, parent, spawnLine("toolu_1", "Agent", false))

	if got := countsBeside(parent); got.Running != 1 {
		t.Errorf("an unreturned synchronous agent was reported finished: %+v", got)
	}
}

// The original bug, which must not come back: an async call returns within
// seconds ("launched successfully") while the child runs on for minutes.
func TestAsyncAgentIsNotDoneJustBecauseItsCallReturned(t *testing.T) {
	resetScanCache()
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "a1", meta("toolu_1"), true)
	writeParentLines(t, parent,
		spawnLine("toolu_1", "Agent", true),
		resultLine("toolu_1"),
	)

	if got := countsBeside(parent); got.Running != 1 {
		t.Errorf("an async agent was ended by its launch receipt: %+v", got)
	}
}

// Absent is unknown, and unknown is treated as async. Guessing "synchronous"
// here would reinstate the bug above for every transcript that omits the field.
func TestSpawnWithoutTheFlagIsNotAssumedSynchronous(t *testing.T) {
	resetScanCache()
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "a1", meta("toolu_1"), true)
	writeParentLines(t, parent,
		spawnLine("toolu_1", "Agent", nil),
		resultLine("toolu_1"),
	)

	if got := countsBeside(parent); got.Running != 1 {
		t.Errorf("a spawn with no run_in_background was inferred synchronous: %+v", got)
	}
}

// A notification is an explicit statement about the agent; the result is an
// inference from its call. An agent resumed after finishing says so, and its
// original result must not overrule that.
func TestANotificationBeatsTheCallResult(t *testing.T) {
	resetScanCache()
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "a1", meta("toolu_1"), true)
	writeParentLines(t, parent,
		spawnLine("toolu_1", "Agent", false),
		resultLine("toolu_1"),
		`{"c":"<task-notification><task-id>a1</task-id><status>running</status></task-notification>"}`,
	)

	if got := countsBeside(parent); got.Running != 1 {
		t.Errorf("a resumed agent was ended by its old result: %+v", got)
	}
}

// The tool was renamed; both spellings spawn.
func TestBothSpawnToolNamesCount(t *testing.T) {
	for _, name := range []string{"Task", "Agent"} {
		t.Run(name, func(t *testing.T) {
			resetScanCache()
			root := t.TempDir()
			parent := writeSession(t, root, "/x/proj", "sess")
			writeSubagent(t, parent, "a1", meta("toolu_1"), true)
			writeParentLines(t, parent,
				spawnLine("toolu_1", name, false),
				resultLine("toolu_1"),
			)

			if got := countsBeside(parent); got.Running != 0 {
				t.Errorf("%s was not recognised as a spawn: %+v", name, got)
			}
		})
	}
}

// A prompt is arbitrary text and routinely quotes field names. Pairing an id
// with a run_in_background found somewhere after it pairs across whatever the
// prompt happens to contain, which is why this is parsed as JSON.
func TestAPromptQuotingTheFieldDoesNotEndTheNextAgent(t *testing.T) {
	resetScanCache()
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "a1", meta("toolu_1"), true)
	writeParentLines(t, parent,
		`{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1",`+
			`"name":"Agent","input":{"prompt":"explain \"run_in_background\":false to me",`+
			`"run_in_background":true}}]}}`,
		resultLine("toolu_1"),
	)

	if got := countsBeside(parent); got.Running != 1 {
		t.Errorf("prose in a prompt decided the agent's liveness: %+v", got)
	}
}

// The roster carries the same answer as the count; a client that reads one and
// a list that reads the other must never disagree.
func TestRosterAgreesWithTheCount(t *testing.T) {
	resetScanCache()
	root := t.TempDir()
	parent := writeSession(t, root, "/x/proj", "sess")
	writeSubagent(t, parent, "a1", meta("toolu_1"), true)
	writeSubagent(t, parent, "a2", meta("toolu_2"), true)
	writeParentLines(t, parent,
		spawnLine("toolu_1", "Agent", false),
		resultLine("toolu_1"),
		spawnLine("toolu_2", "Agent", false),
	)

	roster := subagentsBeside(parent)
	if len(roster) != 2 {
		t.Fatalf("expected 2 subagents, got %d", len(roster))
	}
	byID := map[string]bool{}
	for _, s := range roster {
		byID[s.AgentID] = s.Done
	}
	if !byID["a1"] || byID["a2"] {
		t.Errorf("roster disagrees: a1=%v a2=%v", byID["a1"], byID["a2"])
	}
	if got := countsBeside(parent); got.Running != 1 || got.Total != 2 {
		t.Errorf("count disagrees with the roster: %+v", got)
	}
}
