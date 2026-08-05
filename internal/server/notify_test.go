package server

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/dipeshdulal/gothalo/internal/agentstate"
	"github.com/dipeshdulal/gothalo/internal/config"
)

func composer(t *testing.T) *Server {
	t.Helper()
	return &Server{cfg: &config.Config{ServerID: "srv1", ServerName: "Mac Studio"}}
}

// TestComposeBlockedSaysWhichServerAndWhy is the whole point of the rework: from
// the lock screen alone the notification must answer which machine, which agent,
// and what it is asking.
func TestComposeBlockedSaysWhichServerAndWhy(t *testing.T) {
	s := composer(t)
	st := &agentstate.State{
		AgentStatus: "blocked",
		Blocked: &agentstate.Blocked{
			Question: "Do you want to run `rm -rf build`?",
			Options: []agentstate.Option{
				{Index: 1, Label: "Yes", Selected: true},
				{Index: 2, Label: "No, tell Claude what to do"},
			},
			Category: "dangerous_command_approval",
		},
	}

	n := s.compose("acme/w1:p2", "blocked", "claude — gothalo", 7, st)

	if !strings.Contains(n.title, "Mac Studio") {
		t.Errorf("title = %q, must name the server", n.title)
	}
	if !strings.Contains(n.title, "claude — gothalo") {
		t.Errorf("title = %q, must name the agent", n.title)
	}
	if !strings.Contains(n.body, "rm -rf build") {
		t.Errorf("body = %q, must carry the agent's actual question", n.body)
	}
	if !strings.Contains(n.body, "1. Yes") || !strings.Contains(n.body, "2. No") {
		t.Errorf("body = %q, must list the choices", n.body)
	}
	if n.channel != ChannelBlocked {
		t.Errorf("channel = %q, want %q", n.channel, ChannelBlocked)
	}
	if n.tag != "srv1/acme/w1:p2" {
		t.Errorf("tag = %q, want the server-qualified pane", n.tag)
	}

	if n.data["server_id"] != "srv1" || n.data["server_name"] != "Mac Studio" {
		t.Errorf("data = %v, must identify the bridge", n.data)
	}
	if n.data["state_change_seq"] != "7" {
		t.Errorf("state_change_seq = %q, want 7 (a tray approve echoes it back)", n.data["state_change_seq"])
	}
	if n.data["category"] != "dangerous_command_approval" {
		t.Errorf("category = %q, want the block's semantic class", n.data["category"])
	}

	var opts []agentstate.Option
	if err := json.Unmarshal([]byte(n.data["options"]), &opts); err != nil {
		t.Fatalf("options are not decodable JSON: %v", err)
	}
	if len(opts) != 2 || !opts[0].Selected {
		t.Errorf("options = %v, want both choices with the default marked", opts)
	}
}

// TestComposeBlockedWithoutPrompt: when the prompt can't be read the alert must
// still go out, degraded rather than absent.
func TestComposeBlockedWithoutPrompt(t *testing.T) {
	s := composer(t)
	n := s.compose("w1:p2", "blocked", "", 3, nil)

	if n.body == "" {
		t.Error("body is empty; an unreadable prompt must still produce an alert")
	}
	if !strings.Contains(n.title, "w1:p2") {
		t.Errorf("title = %q, must fall back to the pane id when there is no title", n.title)
	}
	if _, has := n.data["question"]; has {
		t.Error("question key present with no prompt read; it should be omitted")
	}
}

// TestComposeDone uses the quiet channel and reports what finished.
func TestComposeDone(t *testing.T) {
	s := composer(t)
	st := &agentstate.State{AgentStatus: "done", Headline: "Ran the test suite"}
	n := s.compose("w1:p2", "done", "claude", 9, st)

	if n.channel != ChannelDone {
		t.Errorf("channel = %q, want %q so completions don't ring like blocks", n.channel, ChannelDone)
	}
	if !strings.Contains(n.body, "Ran the test suite") {
		t.Errorf("body = %q, must say what finished", n.body)
	}
	if n.data["status"] != "done" {
		t.Errorf("status = %q, want done", n.data["status"])
	}
}

// TestComposeTruncatesBody keeps a runaway prompt from eating the payload budget.
func TestComposeTruncatesBody(t *testing.T) {
	s := composer(t)
	st := &agentstate.State{
		AgentStatus: "blocked",
		Blocked:     &agentstate.Blocked{Question: strings.Repeat("long ", 400)},
	}
	n := s.compose("w1:p2", "blocked", "claude", 1, st)
	if got := len([]rune(n.body)); got > maxBodyRunes {
		t.Errorf("body length = %d runes, want <= %d", got, maxBodyRunes)
	}
}

// TestComposeNoServerName: a bridge with no name must not produce a title with a
// dangling separator.
func TestComposeNoServerName(t *testing.T) {
	s := &Server{cfg: &config.Config{ServerID: "srv1"}}
	n := s.compose("w1:p2", "blocked", "claude", 1, nil)
	if strings.HasPrefix(n.title, "·") || strings.Contains(n.title, " · ") {
		t.Errorf("title = %q, want no separator when the server is unnamed", n.title)
	}
}
