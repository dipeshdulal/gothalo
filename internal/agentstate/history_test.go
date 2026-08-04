package agentstate

import (
	"strings"
	"testing"
)

// TestHistoryBeatsTerminal: when the agent's own transcript is available it
// supplies headline/detail/transcript, and the scraped terminal values are
// discarded. This is the whole point of the structured path — the screen is a
// lossy render of the conversation, the transcript is the conversation.
func TestHistoryBeatsTerminal(t *testing.T) {
	st := Build(Input{
		PaneID: "w1:p1", Kind: "claude", Status: "idle",
		Detection: "  some scraped screen text\n  with chrome\n",
		Recent:    "  older scraped text\n",
		History: []HistoryEntry{
			{Role: "user", Kind: "message", Text: "do the thing"},
			{Role: "assistant", Kind: "message", Text: "Working on it."},
			{Role: "assistant", Kind: "tool_call", Tool: "Bash"},
			{Role: "assistant", Kind: "message", Text: "Done — here is what changed."},
		},
	})

	if st.Detail != "Done — here is what changed." {
		t.Errorf("Detail = %q, want the last assistant message from history", st.Detail)
	}
	if st.Headline != "Done — here is what changed." {
		t.Errorf("Headline = %q, want it derived from history", st.Headline)
	}
	if strings.Contains(st.Detail, "scraped") {
		t.Errorf("Detail still carries terminal text: %q", st.Detail)
	}
	joined := strings.Join(st.Transcript, "\n")
	if !strings.Contains(joined, "do the thing") || !strings.Contains(joined, "· Bash") {
		t.Errorf("Transcript = %v, want the conversation plus a tool marker", st.Transcript)
	}
}

// TestHistorySkipsThinkingAndToolChatter: the headline must be the last thing the
// agent SAID. Reasoning is its scratchpad, and a trailing tool call is not a
// message — both used to be easy to mistake for one when scraping a screen.
func TestHistorySkipsThinkingAndToolChatter(t *testing.T) {
	st := Build(Input{
		PaneID: "w1:p1", Kind: "claude", Status: "working",
		History: []HistoryEntry{
			{Role: "assistant", Kind: "message", Text: "Here's the plan."},
			{Role: "assistant", Kind: "thinking", Text: "I should check the config first"},
			{Role: "assistant", Kind: "tool_call", Tool: "Read"},
			{Role: "tool", Kind: "tool_result", Text: "file contents"},
		},
	})

	if st.Detail != "Here's the plan." {
		t.Errorf("Detail = %q, want the last real assistant message", st.Detail)
	}
	if strings.Contains(strings.Join(st.Transcript, "\n"), "scratchpad") ||
		strings.Contains(strings.Join(st.Transcript, "\n"), "check the config") {
		t.Errorf("Transcript leaked thinking: %v", st.Transcript)
	}
}

// TestNoHistoryKeepsParser: a kind with no transcript reader (or a session that
// can't be resolved) must fall back to the parser's terminal-derived values
// rather than returning an empty card.
func TestNoHistoryKeepsParser(t *testing.T) {
	withHistory := Build(Input{
		PaneID: "w1:p1", Kind: "claude", Status: "idle",
		Detection: claudeIdleDetectionFixture(t),
		History:   []HistoryEntry{{Role: "assistant", Kind: "message", Text: "from transcript"}},
	})
	without := Build(Input{
		PaneID: "w1:p1", Kind: "claude", Status: "idle",
		Detection: claudeIdleDetectionFixture(t),
	})

	if withHistory.Detail != "from transcript" {
		t.Errorf("with history: Detail = %q, want the transcript value", withHistory.Detail)
	}
	if without.Detail == "" {
		t.Error("without history: Detail is empty — the parser fallback must still run")
	}
	if without.Detail == "from transcript" {
		t.Error("without history: got the transcript value with no history supplied")
	}
}

// TestHistoryDoesNotTouchBlocked: Blocked comes only from the screen, because a
// prompt is UI the agent is drawing, not conversation. History must never
// overwrite or invent it.
func TestHistoryDoesNotTouchBlocked(t *testing.T) {
	in := Input{
		PaneID: "w1:p1", Kind: "hermes", Status: "blocked",
		Detection: "╭─ Hermes needs your input ─╮\n│ Pick one?               │\n│ ❯ 1. First              │\n│   2. Second             │\n╰─────────────────────────╯\n",
		History: []HistoryEntry{
			{Role: "assistant", Kind: "message", Text: "a message from the transcript"},
		},
	}
	st := Build(in)

	if st.Blocked == nil {
		t.Fatal("Blocked = nil; history must not suppress the screen-derived prompt")
	}
	if st.Blocked.Question != "Pick one?" {
		t.Errorf("Question = %q, want the screen's prompt", st.Blocked.Question)
	}
	if len(st.Blocked.Options) != 2 {
		t.Errorf("got %d options, want 2 from the screen", len(st.Blocked.Options))
	}
	// ...while the message body still comes from the transcript.
	if st.Detail != "a message from the transcript" {
		t.Errorf("Detail = %q, want the history value", st.Detail)
	}
}

// claudeIdleDetectionFixture is a minimal idle Claude screen — enough for the
// parser to produce a non-empty Detail, so the fallback assertion is meaningful.
func claudeIdleDetectionFixture(t *testing.T) string {
	t.Helper()
	return "⏺ A message rendered on the terminal.\n"
}
